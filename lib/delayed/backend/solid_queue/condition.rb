# frozen_string_literal: true

module Delayed
  module Backend
    module SolidQueue
      Condition = Struct.new(:field, :op, :value) do
        FIELDS = {
          id: :id, queue: :queue, queue_name: :queue, priority: :priority, attempts: :attempts,
          run_at: :run_at, scheduled_at: :run_at, created_at: :created_at, updated_at: :updated_at,
          locked_at: :locked_at, locked_by: :locked_by, failed_at: :failed_at, last_error: :last_error,
          handler: :handler, name: :name
        }.freeze
        SQL_OPERATORS = { "=" => :eq, "!=" => :not_eq, "<>" => :not_eq, "<" => :lt, "<=" => :lte, ">" => :gt, ">=" => :gte }.freeze
        SQL_NULL = /\A(\w+)\s+IS\s+(NOT\s+)?NULL\z/i
        SQL_COMPARISON = /\A(\w+)\s*(<=|>=|<>|!=|=|<|>)\s*(\?|-?\d+|'[^']*')\z/
        NEGATIONS = { null: :not_null, not_null: :null, eq: :not_eq, not_eq: :eq, in: :not_in, not_in: :in,
                      lt: :gte, gte: :lt, gt: :lte, lte: :gt }.freeze

        class << self
          def parse(conditions, binds, negate: false)
            list = case conditions
            when Hash then from_hash(conditions)
            when String then from_sql(conditions, binds)
            when Array then from_sql(conditions.first, conditions.drop(1))
            when nil then []
            else raise ArgumentError, "Delayed::Job can not filter by #{conditions.inspect}"
            end
            negate ? negated(list) : list
          end

          def field(name)
            FIELDS.fetch(name.to_s.split(".").last.to_sym) do
              raise ArgumentError, "Delayed::Job can not filter or order by #{name.inspect}"
            end
          end

          private
            def from_hash(hash)
              hash.flat_map do |key, value|
                name = field(key)
                case value
                when nil then [ new(name, :null) ]
                when Array then [ new(name, :in, value) ]
                when Range then range(name, value)
                else [ new(name, :eq, value) ]
                end
              end
            end

            def range(name, value)
              [].tap do |list|
                list << new(name, :gte, value.begin) unless value.begin.nil?
                list << new(name, value.exclude_end? ? :lt : :lte, value.end) unless value.end.nil?
              end
            end

            def negated(list)
              if list.size == 1
                [ list.first.negate ]
              else
                [ new(list.first.field, :not_all, list) ]
              end
            end

            def from_sql(sql, binds)
              binds = binds.dup
              clauses = sql.to_s.strip.split(/\s+AND\s+/i).map do |clause|
                clause = clause.strip.delete_prefix("(").delete_suffix(")").strip
                if (match = SQL_NULL.match(clause))
                  new(field(match[1]), match[2] ? :not_null : :null)
                elsif (match = SQL_COMPARISON.match(clause))
                  new(field(match[1]), SQL_OPERATORS.fetch(match[2]), sql_value(match[3], binds, sql))
                else
                  untranslatable!(sql)
                end
              end
              untranslatable!(sql) if clauses.empty? || binds.any?
              clauses
            end

            def sql_value(token, binds, sql)
              case token
              when "?" then binds.empty? ? untranslatable!(sql) : binds.shift
              when /\A'/ then token[1..-2]
              else token.to_i
              end
            end

            def untranslatable!(sql)
              raise ArgumentError, "Delayed::Job can not translate #{sql.inspect}; use hash conditions or simple " \
                "\"column <op> ?\" / \"column IS [NOT] NULL\" clauses joined by AND"
            end
        end

        def negate
          self.class.new(field, NEGATIONS.fetch(op) { :"not_#{op}" }, value)
        end

        def matches?(job)
          actual = job.public_send(field)
          case op
          when :eq then same?(actual, value)
          when :not_eq then !same?(actual, value)
          when :in then value.any? { |candidate| same?(actual, candidate) }
          when :not_in then value.none? { |candidate| same?(actual, candidate) }
          when :null then actual.nil?
          when :not_null then !actual.nil?
          when :lt then !actual.nil? && actual < value
          when :lte then !actual.nil? && actual <= value
          when :gt then !actual.nil? && actual > value
          when :gte then !actual.nil? && actual >= value
          when :not_all then !value.all? { |condition| condition.matches?(job) }
          else raise ArgumentError, "unknown Delayed::Job condition #{op.inspect}"
          end
        end

        private
          def same?(actual, expected)
            if field == :id
              actual.to_s == expected.to_s
            elsif actual.respond_to?(:to_time) && expected.respond_to?(:to_time) && !actual.is_a?(String)
              (actual.to_time - expected.to_time).abs < 0.001
            else
              actual == expected
            end
          end
      end
    end
  end
end
