# frozen_string_literal: true

module Delayed
  module Backend
    module SolidQueue
      class Relation
        include Enumerable

        STATUSES = %i[ ready scheduled blocked claimed failed ].freeze
        PUSHDOWN_FIELDS = %i[ id queue priority run_at created_at ].freeze
        PUSHDOWN_OPERATORS = %i[ eq in not_eq not_in lt lte gt gte ].freeze
        STATUS_FIELDS = { failed_at: :failed, locked_at: :claimed }.freeze
        BATCH_SIZE = 500

        class WhereChain
          def initialize(relation)
            @relation = relation
          end

          def not(conditions, *binds)
            @relation.send(:spawn, conditions: Condition.parse(conditions, binds, negate: true))
          end
        end

        Reservable = Struct.new(:worker_name, :cutoff) do
          def matches?(job)
            job.locked_by == worker_name || job.locked_at.nil? || (job.locked_at < cutoff && job.send(:stealable?))
          end
        end

        attr_reader :klass

        def initialize(klass, conditions: [], order: [], limit: nil, offset: nil, reservable: nil)
          @klass = klass
          @conditions = conditions
          @order = order
          @limit = limit
          @offset = offset
          @reservable = reservable
        end

        def all
          self
        end

        def where(conditions = nil, *binds)
          return WhereChain.new(self) if conditions.nil?

          spawn(conditions: Condition.parse(conditions, binds))
        end

        def order(*args)
          specs = args.flat_map do |arg|
            case arg
            when Hash then arg.map { |name, direction| [ Condition.field(name), direction(direction) ] }
            when String then arg.split(",").map { |part| order_spec(part) }
            else [ [ Condition.field(arg), :asc ] ]
            end
          end
          spawn(order: specs)
        end

        def reorder(*args)
          self.class.new(klass, conditions: @conditions, limit: @limit, offset: @offset, reservable: @reservable).order(*args)
        end

        def limit(value)
          spawn(limit: value)
        end

        def offset(value)
          spawn(offset: value)
        end

        def reservable(worker_name, max_run_time, now = klass.db_time_now)
          spawn(reservable: Reservable.new(worker_name, now - max_run_time), conditions: [], now: now)
        end

        def each(&block)
          to_a.each(&block)
        end

        def to_a
          load_jobs
        end
        alias_method :to_ary, :to_a
        alias_method :load, :to_a

        def count
          return to_a.size if @limit || @offset || plan.any? { |step| step.memory.any? }

          plan.sum { |step| store.count(step.status, step.pushdown) }
        end
        alias_method :size, :count

        def length
          to_a.length
        end

        def exists?
          limit(1).to_a.any?
        end

        def empty?
          !exists?
        end

        def any?(*args, &block)
          args.empty? && block.nil? ? exists? : super
        end

        def none?(*args, &block)
          args.empty? && block.nil? ? !exists? : super
        end

        def first(count = nil)
          count ? limit(count).to_a : limit(1).to_a.first
        end

        def last(count = nil)
          reversed = spawn_replacing_order(effective_order.map { |name, direction| [ name, direction == :asc ? :desc : :asc ] })
          count ? reversed.limit(count).to_a.reverse : reversed.limit(1).to_a.first
        end

        def find(id)
          where(id: id).first || raise(RecordNotFound, "Couldn't find Delayed::Job with 'id'=#{id}")
        end

        def find_by(conditions = nil, *binds)
          where(conditions, *binds).first
        end

        def find_by!(conditions = nil, *binds)
          find_by(conditions, *binds) || raise(RecordNotFound, "Couldn't find Delayed::Job")
        end

        def find_each(batch_size: 1000, &block)
          return enum_for(:find_each, batch_size: batch_size) unless block

          find_in_batches(batch_size: batch_size) { |batch| batch.each(&block) }
        end

        def find_in_batches(batch_size: 1000)
          last_id = nil
          loop do
            scope = spawn_replacing_order([ [ :id, :asc ] ]).limit(batch_size)
            scope = scope.spawn(conditions: [ Condition.new(:id, :gt, last_id) ]) if last_id
            batch = scope.to_a
            break if batch.empty?

            yield batch
            break if batch.size < batch_size

            last_id = batch.last.id
          end
        end

        def pluck(*names)
          fields = names.map { |name| Condition.field(name) }
          to_a.map { |job| fields.one? ? job.public_send(fields.first) : fields.map { |field| job.public_send(field) } }
        end

        def ids
          pluck(:id)
        end

        def delete_all
          return delete_jobs(to_a) if @limit || @offset

          plan.sum { |step| delete_matching(step) }
        end

        def destroy_all
          to_a.each(&:destroy)
        end

        def update_all(attributes)
          to_a.count { |job| job.update(attributes) }
        end

        def inspect
          entries = limit(11).to_a
          "#<#{self.class.name} [#{entries.first(10).map(&:inspect).join(", ")}#{", ..." if entries.size > 10}]>"
        end

        protected
          def spawn(conditions: [], order: nil, limit: :keep, offset: :keep, reservable: :keep, now: nil)
            self.class.new(
              klass,
              conditions: @conditions + conditions,
              order: order ? @order + order : @order,
              limit: limit == :keep ? @limit : limit,
              offset: offset == :keep ? @offset : offset,
              reservable: reservable == :keep ? @reservable : reservable
            ).tap { |relation| relation.instance_variable_set(:@now, now || @now) }
          end

          def spawn_replacing_order(order)
            spawn.tap { |relation| relation.instance_variable_set(:@order, order) }
          end

        private
          Step = Struct.new(:status, :pushdown, :memory)

          def store
            klass.store
          end

          def direction(value)
            value.to_s.downcase == "desc" ? :desc : :asc
          end

          def order_spec(part)
            name, dir = part.strip.split(/\s+/)
            [ Condition.field(name), direction(dir) ]
          end

          def effective_order
            @order.presence || [ [ :id, :asc ] ]
          end

          def plan
            @plan ||= statuses.map do |status|
              pushdown, memory = @conditions.partition { |condition| pushdown?(condition, status) }
              memory = memory.reject { |condition| decided_by_status?(condition) }
              if @reservable
                pushdown += [ Condition.new(:run_at, :lte, @now) ] if status == :scheduled
                memory += [ @reservable ] if status == :claimed
              end
              Step.new(status, pushdown, memory)
            end
          end

          def statuses
            list = @reservable ? %i[ ready scheduled claimed ] : STATUSES.dup
            @conditions.each do |condition|
              status = status_for(condition.field)
              next unless status

              case condition.op
              when :null then list -= [ status ]
              when :not_null, :eq, :in, :lt, :lte, :gt, :gte then list &= [ status ]
              end
            end
            list
          end

          def status_for(field)
            field == :locked_by ? :claimed : STATUS_FIELDS[field]
          end

          def decided_by_status?(condition)
            status_for(condition.field) && %i[ null not_null ].include?(condition.op)
          end

          def pushdown?(condition, status)
            return false unless PUSHDOWN_OPERATORS.include?(condition.op)
            return false if condition.op.in?(%i[ in not_in ]) && condition.value.any?(&:nil?)
            return false if condition.value.nil?

            PUSHDOWN_FIELDS.include?(condition.field) || STATUS_FIELDS[condition.field] == status
          end

          def memory_sort?
            effective_order.any? { |name, _| !PUSHDOWN_FIELDS.include?(name) && !STATUS_FIELDS.key?(name) }
          end

          def pushdown_order(status)
            effective_order.select { |name, _| PUSHDOWN_FIELDS.include?(name) || STATUS_FIELDS[name] == status }
          end

          def load_jobs
            window = @limit && !memory_sort? ? (@offset || 0) + @limit : nil
            jobs = plan.flat_map do |step|
              records = store.fetch(step.status, step.pushdown, order: memory_sort? ? [] : pushdown_order(step.status),
                limit: step.memory.empty? ? window : nil)
              records.map { |record| klass.from_record(record) }.select { |job| step.memory.all? { |condition| condition.matches?(job) } }
            end
            jobs = sort(jobs)
            jobs = jobs.drop(@offset) if @offset
            @limit ? jobs.first(@limit) : jobs
          end

          def sort(jobs)
            keys = effective_order + [ [ :id, :asc ] ]
            jobs.sort { |a, b| compare(a, b, keys) }
          end

          def compare(a, b, keys)
            keys.each do |name, dir|
              left = sort_value(a, name)
              right = sort_value(b, name)
              result = if left.nil? && right.nil? then 0
              elsif left.nil? then -1
              elsif right.nil? then 1
              else left <=> right
              end
              result = -result if dir == :desc
              return result unless result.nil? || result.zero?
            end
            0
          end

          def sort_value(job, name)
            value = job.public_send(name)
            name == :id && value.is_a?(String) && !value.match?(/\A\h{24}\z/) ? value.to_i : value
          end

          def delete_matching(step)
            deleted = 0
            last_id = nil
            loop do
              conditions = step.pushdown + (last_id ? [ Condition.new(:id, :gt, last_id) ] : [])
              records = store.fetch(step.status, conditions, order: [ [ :id, :asc ] ], limit: BATCH_SIZE)
              break if records.empty?

              last_id = records.last.job.id
              selected = if step.memory.empty?
                records
              else
                records.select { |record| step.memory.all? { |condition| condition.matches?(klass.from_record(record)) } }
              end
              deleted += store.delete(step.status, selected.map(&:job)) if selected.any?
              break if records.size < BATCH_SIZE
            end
            deleted
          end

          def delete_jobs(jobs)
            jobs.group_by(&:status).sum { |status, group| store.delete(status, group.map { |job| job.send(:record).job }) }
          end
      end
    end
  end
end
