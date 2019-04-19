require 'active_record'

module MultiTenant
  class Table
    attr_reader :arel_table

    def initialize(arel_table)
      @arel_table = arel_table
    end

    def eql?(rhs)
      self.class == rhs.class &&
        equality_fields.eql?(rhs.equality_fields)
    end

    def hash
      equality_fields.hash
    end

    protected

    def equality_fields
      [arel_table.name, arel_table.table_alias]
    end
  end

  class Context
    attr_reader :arel_node, :known_relations, :handled_relations

    def initialize(arel_node)
      @arel_node = arel_node
      @known_relations = []
      @handled_relations = []
    end

    def discover_relations
      old_discovering = @discovering
      @discovering = true
      yield
      @discovering = old_discovering
    end

    def visited_relation(relation)
      return unless @discovering
      @known_relations << Table.new(relation)
    end

    def visited_handled_relation(relation)
      @handled_relations << Table.new(relation)
    end

    def unhandled_relations
      known_relations.uniq - handled_relations
    end
  end

  class ArelTenantVisitor < Arel::Visitors::DepthFirst
    def initialize(arel)
      super(Proc.new {})
      @statement_node_id = nil

      @contexts = []
      @current_context = nil
      accept(arel.ast)
    end

    attr_reader :contexts

    def visit_Arel_Attributes_Attribute(*args)
      return if @current_context.nil?
      super(*args)
    end

    def visit_Arel_Nodes_Equality(o, *args)
      if o.left.is_a?(Arel::Attributes::Attribute)
        table_name = o.left.relation.table_name
        model = MultiTenant.multi_tenant_model_for_table(table_name)
        @current_context.visited_handled_relation(o.left.relation) if model.present? && o.left.name.to_s == model.partition_key.to_s
      end
      super(o, *args)
    end

    def visit_MultiTenant_TenantEnforcementClause(o, *)
      @current_context.visited_handled_relation(o.tenant_attribute.relation)
    end

    def visit_MultiTenant_TenantJoinEnforcementClause(o, *)
      @current_context.visited_handled_relation(o.tenant_attribute.relation)
    end

    def visit_Arel_Table(o, _collector = nil)
      @current_context.visited_relation(o) if tenant_relation?(o.table_name)
    end
    alias :visit_Arel_Nodes_TableAlias :visit_Arel_Table

    def visit_Arel_Nodes_SelectCore(o, *args)
      nest_context(o) do
        @current_context.discover_relations do
          visit o.source
        end
        visit o.wheres
        visit o.groups
        visit o.windows
        if defined?(o.having)
          visit o.having
        else
          visit o.havings
        end
      end
    end

    def visit_Arel_Nodes_OuterJoin(o, collector = nil)
      nest_context(o) do
        @current_context.discover_relations do
          visit o.left
          visit o.right
        end
      end
    end
    alias :visit_Arel_Nodes_FullOuterJoin :visit_Arel_Nodes_OuterJoin
    alias :visit_Arel_Nodes_RightOuterJoin :visit_Arel_Nodes_OuterJoin

    private

    def tenant_relation?(table_name)
      MultiTenant.multi_tenant_model_for_table(table_name).present?
    end

    DISPATCH = Hash.new do |hash, klass|
      hash[klass] = "visit_#{(klass.name || '').gsub('::', '_')}"
    end

    def dispatch
      DISPATCH
    end

    def get_dispatch_cache
      dispatch
    end

    def nest_context(o)
      old_context = @current_context
      @current_context = Context.new(o)
      @contexts << @current_context

      yield

      @current_context = old_context
    end
  end

  class TenantEnforcementClause < Arel::Nodes::Node
    attr_reader :tenant_attribute
    def initialize(tenant_attribute)
      @tenant_attribute = tenant_attribute
    end

    def to_s; to_sql; end
    def to_str; to_sql; end

    def to_sql(*)
      tenant_arel.to_sql
    end

    private

    def tenant_arel
      if defined?(Arel::Nodes::Quoted)
        @tenant_attribute.eq(Arel::Nodes::Quoted.new(MultiTenant.current_tenant_id))
      else
        @tenant_attribute.eq(MultiTenant.current_tenant_id)
      end
    end
  end


  class TenantJoinEnforcementClause < Arel::Nodes::Node
    attr_reader :table_right
    attr_reader :table_left
    def initialize(table_right, table_left)
      @table_left = table_left
      @model_right = MultiTenant.multi_tenant_model_for_table(table_right.table_name)
      @model_left = MultiTenant.multi_tenant_model_for_table(table_left.table_name)
      @tenant_attribute = table_right[@model_right.partition_key]
    end

    def to_s; to_sql; end
    def to_str; to_sql; end

    def to_sql(*)
      tenant_arel.to_sql
    end

    private

    def tenant_arel
      @tenant_attribute.eq(@table_left[@model_left.partition_key])
    end
  end


  module TenantValueVisitor
    if ActiveRecord::VERSION::MAJOR > 4 || (ActiveRecord::VERSION::MAJOR == 4 && ActiveRecord::VERSION::MINOR >= 2)
      def visit_MultiTenant_TenantEnforcementClause(o, collector)
        collector << o
      end

      def visit_MultiTenant_TenantJoinEnforcementClause(o, collector)
        collector << o
      end

    else
      def visit_MultiTenant_TenantEnforcementClause(o, a = nil)
        o
      end

      def visit_MultiTenant_TenantJoinEnforcementClause(o, a = nil)
        o
      end
    end
  end

  module DatabaseStatements
    def join_to_update(update, *args)
      update = super(update, *args)
      model = MultiTenant.multi_tenant_model_for_table(update.ast.relation.table_name)
      if model.present? && !MultiTenant.with_write_only_mode_enabled?
        update.where(MultiTenant::TenantEnforcementClause.new(model.arel_table[model.partition_key]))
      end
      update
    end

    def join_to_delete(delete, *args)
      delete = super(delete, *args)
      model = MultiTenant.multi_tenant_model_for_table(delete.ast.left.table_name)
      if model.present? && !MultiTenant.with_write_only_mode_enabled?
        delete.where(MultiTenant::TenantEnforcementClause.new(model.arel_table[model.partition_key]))
      end
      delete
    end

    if ActiveRecord::VERSION::MAJOR >= 5 && ActiveRecord::VERSION::MINOR >= 2
      def update(arel, name = nil, binds = [])
        model = MultiTenant.multi_tenant_model_for_table(arel.ast.relation.table_name)
        if model.present? && !MultiTenant.with_write_only_mode_enabled?
          arel.where(MultiTenant::TenantEnforcementClause.new(model.arel_table[model.partition_key]))
        end
        super(arel, name, binds)
      end

      def delete(arel, name = nil, binds = [])
        model = MultiTenant.multi_tenant_model_for_table(arel.ast.left.table_name)
        if model.present? && !MultiTenant.with_write_only_mode_enabled?
          arel.where(MultiTenant::TenantEnforcementClause.new(model.arel_table[model.partition_key]))
        end
        super(arel, name, binds)
      end
    end
  end
end

require 'active_record/connection_adapters/abstract_adapter'
ActiveRecord::ConnectionAdapters::AbstractAdapter.prepend(MultiTenant::DatabaseStatements)

Arel::Visitors::ToSql.include(MultiTenant::TenantValueVisitor)

require 'active_record/relation'
module ActiveRecord
  module QueryMethods
    alias :build_arel_orig :build_arel
    def build_arel(*args)
      arel = build_arel_orig(*args)

      if !MultiTenant.with_write_only_mode_enabled?
        visitor = MultiTenant::ArelTenantVisitor.new(arel)

        visitor.contexts.each do |context|
          node = context.arel_node
          node_right = node.source.right

          context.unhandled_relations.each do |relation|
            model = MultiTenant.multi_tenant_model_for_table(relation.arel_table.table_name)

            if MultiTenant.current_tenant_id
              enforcement_clause = MultiTenant::TenantEnforcementClause.new(relation.arel_table[model.partition_key])

              case node
              when Arel::Nodes::Join #Arel::Nodes::OuterJoin, Arel::Nodes::RightOuterJoin, Arel::Nodes::FullOuterJoin
                node.right.expr = node.right.expr.and(enforcement_clause)
              when Arel::Nodes::SelectCore
                if node.wheres.empty?
                  node.wheres = [enforcement_clause]
                else
                  node.wheres[0] = enforcement_clause.and(node.wheres[0])
                end
              else
                raise "UnknownContext"
              end
            end

            node_right.select{ |n| n.is_a? Arel::Nodes::Join }.each do |node_join|
              join_enforcement_clause = MultiTenant::TenantJoinEnforcementClause.new(relation.arel_table, node_join.left)
              node_join.right.expr = node_join.right.expr.and(join_enforcement_clause)
            end
          end
        end
      end

      arel
    end
  end
end

require 'active_record/base'
module MultiTenantFindBy
  if ActiveRecord::VERSION::MAJOR == 4 && ActiveRecord::VERSION::MINOR >= 2
    # Disable caching for find and find_by in Rails 4.2 - we don't have a good
    # way to prevent caching problems here when prepared statements are enabled
    def find_by(*args)
      return super unless respond_to?(:scoped_by_tenant?) && scoped_by_tenant?

      # This duplicates a bunch of code from AR's find() method
      return super if current_scope || !(Hash === args.first) || reflect_on_all_aggregations.any?
      return super if default_scopes.any?

      hash = args.first

      return super if hash.values.any? { |v| v.nil? || Array === v || Hash === v }
      return super unless hash.keys.all? { |k| columns_hash.has_key?(k.to_s) }

      key = hash.keys

      # Ensure we never use the cached version
      find_by_statement_cache.synchronize { find_by_statement_cache[key] = nil }

      super
    end

    def find(*ids)
      return super unless respond_to?(:scoped_by_tenant?) && scoped_by_tenant?

      # This duplicates a bunch of code from AR's find() method
      return super unless ids.length == 1
      return super if ids.first.kind_of?(Symbol)
      return super if block_given? ||
                      primary_key.nil? ||
                      default_scopes.any? ||
                      current_scope ||
                      columns_hash.include?(inheritance_column) ||
                      ids.first.kind_of?(Array)

      id = ids.first
        if ActiveRecord::Base === id
          id = id.id
          ActiveSupport::Deprecation.warn(<<-MSG.squish)
            You are passing an instance of ActiveRecord::Base to `find`.
            Please pass the id of the object by calling `.id`
          MSG
        end
      key = primary_key

      # Ensure we never use the cached version
      find_by_statement_cache.synchronize { find_by_statement_cache[key] = nil }

      super
    end
  elsif ActiveRecord::VERSION::MAJOR > 4
    def cached_find_by_statement(key, &block)
      return super unless respond_to?(:scoped_by_tenant?) && scoped_by_tenant?

      key = Array.wrap(key) + [MultiTenant.current_tenant_id.to_s]
      super(key, &block)
    end
  end
end

ActiveRecord::Base.singleton_class.prepend(MultiTenantFindBy)
