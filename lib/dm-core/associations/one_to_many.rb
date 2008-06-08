require 'forwardable'

module DataMapper
  module Associations
    module OneToMany

      # Setup one to many relationship between two models
      # -
      # @private
      def setup(name, model, options = {})
        raise ArgumentError, "+name+ should be a Symbol (or Hash for +through+ support), but was #{name.class}", caller unless Symbol === name || Hash === name
        raise ArgumentError, "+options+ should be a Hash, but was #{options.class}", caller                             unless Hash   === options

        repository_name = model.repository.name

        model.class_eval <<-EOS, __FILE__, __LINE__
          def #{name}(query = {})
            query.empty? ? #{name}_association : #{name}_association.all(query)
          end

          def #{name}=(children)
            #{name}_association.replace(children)
          end

          private

          def #{name}_association
            @#{name}_association ||= begin
              relationship = self.class.relationships(#{repository_name.inspect})[#{name.inspect}]
              raise ArgumentError.new("Relationship #{name.inspect} does not exist") unless relationship
              association = Proxy.new(relationship, self)
              parent_associations << association
              association
            end
          end
        EOS

        model.relationships(repository_name)[name] = if options.has_key?(:through)
          RelationshipChain.new(
            :child_model_name         => options.fetch(:class_name, Extlib::Inflection.classify(name)),
            :parent_model_name        => model.name,
            :repository_name          => repository_name,
            :near_relationship_name   => options[:through],
            :remote_relationship_name => options.fetch(:remote_name, name),
            :parent_key               => options[:parent_key],
            :child_key                => options[:child_key]
          )
        else
          Relationship.new(
            Extlib::Inflection.underscore(Extlib::Inflection.demodulize(model.name)).to_sym,
            repository_name,
            options.fetch(:class_name, Extlib::Inflection.classify(name)),
            model.name,
            options
          )
        end
      end

      module_function :setup

      class Proxy
        instance_methods.each { |m| undef_method m unless %w[ __id__ __send__ class kind_of? respond_to? should should_not ].include?(m) }

        def replace(resources)
          each { |resource| orphan_resource(resource) }
          resources.each { |resource| relate_resource(resource) }
          super
        end

        def push(*resources)
          resources.each { |resource| relate_resource(resource) }
          super
        end

        def unshift(*resources)
          resources.each { |resource| relate_resource(resource) }
          super
        end

        def <<(resource)
          #
          # The order here is of the essence.
          #
          # self.relate_resource used to be called before children.<<, which created weird errors
          # where the resource was appended in the db before it was appended onto the @children
          # structure, that was just read from the database, and therefore suddenly had two
          # elements instead of one after the first addition.
          #
          super
          relate_resource(resource)
          self
        end

        def pop
          orphan_resource(super)
        end

        def shift
          orphan_resource(super)
        end

        def delete(resource, &block)
          orphan_resource(super)
        end

        def delete_at(index)
          orphan_resource(super)
        end

        def clear
          each { |resource| orphan_resource(resource) }
          super
          self
        end

        def save
          @dirty_children.each { |resource| save_resource(resource) }
          @dirty_children = []
          @children = @relationship.get_children(@parent_resource).replace(@children) unless @children.kind_of?(Collection)
          self
        end

        def reload!
          @dirty_children = []
          @children = nil
          self
        end

        def respond_to?(method)
          super || children.respond_to?(method)
        end

        private

        def initialize(relationship, parent_resource)
#          raise ArgumentError, "+relationship+ should be a DataMapper::Association::Relationship, but was #{relationship.class}", caller unless Relationship === relationship
#          raise ArgumentError, "+parent_resource+ should be a DataMapper::Resource, but was #{parent_resource.class}", caller            unless Resource     === parent_resource

          @relationship    = relationship
          @parent_resource = parent_resource
          @dirty_children  = []
        end

        def children
          @children ||= @relationship.get_children(@parent_resource)
        end

        def assert_mutable
          raise ImmutableAssociationError, "You can not modify this assocation" if RelationshipChain === @relationship
        end

        # TODO: move this logic inside the Collection
        def add_default_association_values(resource)
          conditions = @relationship.query.reject { |key, value| key == :order }
          conditions.each do |key, value|
            resource.send("#{key}=", value) if key.class != DataMapper::Query::Operator && resource.send("#{key}") == nil
          end
        end

        def relate_resource(resource)
          assert_mutable
          add_default_association_values(resource)
          if @parent_resource.new_record?
            @dirty_children << resource
          else
            save_resource(resource)
          end
          resource
        end

        def orphan_resource(resource)
          assert_mutable
          begin
            repository(@relationship.repository_name) do
              @relationship.attach_parent(resource, nil)
              resource.save
            end
          rescue
            children << resource
            raise
          end
          resource
        end

        def save_resource(resource)
          assert_mutable
          repository(@relationship.repository_name) do
            @relationship.attach_parent(resource, @parent_resource)
            resource.save
          end
        end

        def method_missing(method, *args, &block)
          results = children.__send__(method, *args, &block)

          return self if LazyArray::RETURN_SELF.include?(method) && results.kind_of?(Array)

          results
        end
      end # class Proxy
    end # module OneToMany
  end # module Associations
end # module DataMapper
