# encoding: utf-8
# author: Dominik Richter
# author: Stephan Renatus
# author: Christoph Hartmann

module FilterTable
  module Show; end

  class ExceptionCatcher
    def initialize(original_resource, original_exception)
      @original_resource = original_resource
      @original_exception = original_exception
    end

    # This method is called via the runner and signals RSpec to output a block
    # showing why the resource was skipped. This prevents the resource from
    # being added to the test collection and being evaluated.
    def resource_skipped?
      @original_exception.is_a?(Inspec::Exceptions::ResourceSkipped)
    end

    # This method is called via the runner and signals RSpec to output a block
    # showing why the resource failed. This prevents the resource from
    # being added to the test collection and being evaluated.
    def resource_failed?
      @original_exception.is_a?(Inspec::Exceptions::ResourceFailed)
    end

    def resource_exception_message
      @original_exception.message
    end

    # Capture message chains and return `ExceptionCatcher` objects
    def method_missing(*)
      self
    end

    # RSpec will check the object returned to see if it responds to a method
    # before calling it. We need to fake it out and tell it that it does. This
    # allows it to skip past that check and fall through to #method_missing
    def respond_to?(_method)
      true
    end

    def to_s
      @original_resource.to_s
    end
    alias inspect to_s
  end

  class Trace
    def initialize
      @chain = []
    end

    %w{== != >= > < <= =~ !~}.each do |m|
      define_method m.to_sym do |*args|
        res = Trace.new
        @chain.push([[m.to_sym] + args, res])
        res
      end
    end

    def method_missing(*args)
      res = Trace.new
      @chain.push([args, res])
      res
    end

    def self.to_ruby(trace)
      chain = trace.instance_variable_get(:@chain)
      return '' if chain.empty?
      ' ' + chain.map do |el|
        m = el[0][0]
        args = el[0].drop(1)
        nxt = to_ruby(el[1])
        next m.to_s + nxt if args.empty?
        next m.to_s + ' ' + args[0].inspect + nxt if args.length == 1
        m.to_s + '(' + args.map(&:inspect).join(', ') + ')' + nxt
      end.join(' ')
    end
  end

  class Table
    attr_reader :params, :resource
    def initialize(resource, params, filters)
      @resource = resource
      @params = params
      @params = [] if @params.nil?
      @filters = filters
      @populated_lazy_columns = {}
    end

    def where(conditions = {}, &block)
      return self if !conditions.is_a?(Hash)
      return self if conditions.empty? && !block_given?

      filters = ''
      table = @params
      conditions.each do |field, condition|
        populate_lazy_field(field, condition) if is_field_lazy?(field)
        filters += " #{field} == #{condition.inspect}"
        table = filter_lines(table, field, condition)
      end

      if block_given?
        table = table.find_all { |e| new_entry(e, '').instance_eval(&block) }
        src = Trace.new
        src.instance_eval(&block)
        filters += Trace.to_ruby(src)
      end

      self.class.new(@resource, table, @filters + filters)
    end

    def new_entry(*_)
      raise "#{self.class} must not be used on its own. It must be inherited "\
           'and the #new_entry method must be implemented. This is an internal '\
           'error and should not happen.'
    end

    def entries
      f = @resource.to_s + @filters.to_s + ' one entry'
      @params.map do |line|
        new_entry(line, f)
      end
    end

    def get_field(field)
      @params.map do |line|
        line[field]
      end
    end

    def to_s
      @resource.to_s + @filters
    end

    alias inspect to_s

    def populate_lazy_field(field_name, criterion)
      return unless is_field_lazy?(field_name)
      return if field_populated?(field_name)
      @params.each do |row|
        next if row.key?(field_name) # skip row if pre-existing data is present
        row[field_name] = callback_for_lazy_field(field_name).call(row, criterion, self)
      end
      @populated_lazy_columns[field_name] = true
    end

    def is_field_lazy?(sought_field_name)
      connector_schema.values.any? do |connector_struct|
        sought_field_name == connector_struct.field_name && \
          connector_struct.opts[:lazy]
      end
    end

    def callback_for_lazy_field(field_name)
      return unless is_field_lazy?(field_name)
      connector_schema.values.find do |connector_struct|
        connector_struct.field_name == field_name
      end.opts[:lazy]
    end

    def field_populated?(field_name)
      @populated_lazy_columns[field_name]
    end

    private

    def matches_float(x, y)
      return false if x.nil?
      return false if !x.is_a?(Float) && (x =~ /\A[-+]?(\d+\.?\d*|\.\d+)\z/).nil?
      x.to_f == y
    end

    def matches_int(x, y)
      return false if x.nil?
      return false if !x.is_a?(Integer) && (x =~ /\A[-+]?\d+\z/).nil?
      x.to_i == y
    end

    def matches_regex(x, y)
      return x == y if x.is_a?(Regexp)
      !x.to_s.match(y).nil?
    end

    def matches(x, y)
      x === y # rubocop:disable Style/CaseEquality
    end

    def filter_lines(table, field, condition)
      m = case condition
          when Float   then method(:matches_float)
          when Integer then method(:matches_int)
          when Regexp  then method(:matches_regex)
          else              method(:matches)
          end

      table.find_all do |line|
        next unless line.key?(field)
        m.call(line[field], condition)
      end
    end
  end

  class Factory
    Connector = Struct.new(:field_name, :block, :opts)

    def initialize
      @accessors = []
      @connectors = {}
      @resource = nil
    end

    def connect(resource, table_accessor) # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      # create the table structure
      connectors = @connectors
      struct_fields = connectors.values.map(&:field_name)
      connector_blocks = connectors.map do |method, c|
        [method.to_sym, create_connector(c)]
      end

      # the struct to hold single items from the #entries method
      entry_struct = Struct.new(*struct_fields.map(&:to_sym)) do
        attr_accessor :__filter
        attr_accessor :__filter_table
        def to_s
          @__filter || super
        end
      end unless struct_fields.empty?

      # the main filter table
      table = Class.new(Table) {
        connector_blocks.each do |x|
          define_method x[0], &x[1]
        end

        define_method :connector_schema do
          connectors
        end

        define_method :new_entry do |hashmap, filter = ''|
          return entry_struct.new if hashmap.nil?
          res = entry_struct.new(*struct_fields.map { |x| hashmap[x] })
          res.__filter = filter
          res.__filter_table = self
          res
        end
      }

      # Now that the table class is defined and the row struct is defined,
      # extend the row struct to support triggering population of lazy fields
      # in where blocks. To do that, we'll need a reference to the table (which
      # knows which fields are populated, and how to populated them) and we'll need to
      # override the getter method for each lazy field, so it will trigger
      # population if needed.  Keep in mind we don't have to adjust the constructor
      # args of the row struct; also the Struct class will already have provided
      # a setter for each field.
      connectors.values.each do |connector_info|
        next unless connector_info.opts[:lazy]
        field_name = connector_info.field_name.to_sym
        entry_struct.send(:define_method, field_name) do
          unless __filter_table.field_populated?(field_name)
            __filter_table.populate_lazy_field(field_name, Show) # No access to criteria here
            # OK, the underlying raw data has the value in the first row
            # (because we would trigger population only on the first row)
            # We could just return the value, but we need to set it on this Struct in case it is referenced multiple times
            # in the where block.
            self[field_name] = __filter_table.params[0][field_name]
          end
          # Now return the value using the Struct getter, whether newly populated or not
          self[field_name]
        end
      end

      # Define all access methods with the parent resource
      # These methods will be configured to return an `ExceptionCatcher` object
      # that will always return the original exception, but only when called
      # upon. This will allow method chains in `describe` statements to pass the
      # `instance_eval` when loaded and only throw-and-catch the exception when
      # the tests are run.
      accessors = @accessors + @connectors.keys
      accessors.each do |method_name|
        resource.send(:define_method, method_name.to_sym) do |*args, &block|
          begin
            filter = table.new(self, method(table_accessor).call, ' with')
            filter.method(method_name.to_sym).call(*args, &block)
          rescue Inspec::Exceptions::ResourceFailed, Inspec::Exceptions::ResourceSkipped => e
            FilterTable::ExceptionCatcher.new(resource, e)
          end
        end
      end
    end

    def add_accessor(method_name)
      if method_name.nil?
        throw RuntimeError, "Called filter.add_delegator for resource #{@resource} with method name nil!"
      end
      @accessors.push(method_name)
      self
    end

    def add(method_name, opts = {}, &block)
      if method_name.nil?
        throw RuntimeError, "Called filter.add for resource #{@resource} with method name nil!"
      end

      @connectors[method_name.to_sym] =
        Connector.new(opts[:field] || method_name, block, opts)
      self
    end

    private

    def create_connector(c)
      return ->(cond = Show) { c.block.call(self, cond) } if !c.block.nil?

      lambda { |condition = Show, &cond_block|
        if condition == Show && !block_given?
          r = where(nil)
          if c.opts[:lazy]
            r.populate_lazy_field(c.field_name, condition)
          end
          r = r.get_field(c.field_name)
          r = r.flatten.uniq.compact if c.opts[:style] == :simple
          r
        else
          where({ c.field_name => condition }, &cond_block)
        end
      }
    end
  end

  def self.create
    Factory.new
  end
end
