# frozen_string_literal: true

require "action_view/ripper_ast_parser"

module ActionView
  class RenderParser # :nodoc:
    def initialize(name, code)
      @name = name
      @code = code
      @parser = RipperASTParser
    end

    def render_calls
      render_nodes = @parser.parse_render_nodes(@code)

      render_nodes.map do |method, nodes|
        nodes.map { |n| send(:parse_render, n) }
      end.flatten.compact
    end

    private
      def directory
        File.dirname(@name)
      end

      def resolve_path_directory(path)
        if path.include?("/")
          path
        else
          "#{directory}/#{path}"
        end
      end

      # Convert
      #   render("foo", ...)
      # into either
      #   render(template: "foo", ...)
      # or
      #   render(partial: "foo", ...)
      def normalize_args(primary_arg, options_hash)
        if primary_arg.class_call?
          { renderable: primary_arg }
        elsif options_hash
          { partial: primary_arg, locals: options_hash }
        else
          { partial: primary_arg }
        end
      end

      def parse_render(node)
        node = node.argument_nodes

        if (node.length == 1 || node.length == 2) && !node[0].hash?
          if node.length == 1
            options = normalize_args(node[0], nil)
          elsif node.length == 2
            options = normalize_args(node[0], node[1])
          end

          return nil unless options

          parse_render_from_options(options)
        elsif node.length == 1 && node[0].hash?
          options = parse_hash_to_symbols(node[0])

          return nil unless options

          parse_render_from_options(options)
        else
          nil
        end
      end

      def parse_hash(node)
        node.hash? && node.to_hash
      end

      def parse_hash_to_symbols(node)
        hash = parse_hash(node)

        return unless hash

        hash.transform_keys do |key_node|
          key = parse_sym(key_node)

          return unless key

          key
        end
      end

      ALL_KNOWN_KEYS = [:partial, :template, :layout, :formats, :locals, :object, :collection, :as, :status, :content_type, :location, :spacer_template]

      RENDER_TYPE_KEYS =
        [:partial, :template, :layout]

      def parse_render_from_options(options_hash)
        renders = []
        keys = options_hash.keys

        if (keys & RENDER_TYPE_KEYS).size < 1
          # Must have at least one of render keys
          return nil
        end

        unless (keys - ALL_KNOWN_KEYS).empty?
          # de-opt in case of unknown option
          return nil
        end

        render_type = (keys & RENDER_TYPE_KEYS)[0]

        node = options_hash[render_type]

        if node.string?
          template = resolve_path_directory(node.to_string)
        elsif render_type == :renderable
          template = node.calling_class_name
        else
          if node.variable_reference?
            dependency = node.variable_name.sub(/\A(?:\$|@{1,2})/, "")
          elsif node.vcall?
            dependency = node.variable_name
          elsif node.call?
            dependency = node.call_method_name
          else
            return
          end

          object_template = true
          template = "#{dependency.pluralize}/#{dependency.singularize}"
        end

        return unless template

        if spacer_template = render_template_with_spacer?(options_hash)
          virtual_path = partial_to_virtual_path(:partial, spacer_template)
          renders << virtual_path
        end

        if options_hash.key?(:object) || options_hash.key?(:collection) || object_template
          return nil if options_hash.key?(:object) && options_hash.key?(:collection)
          return nil unless options_hash.key?(:partial)

          if options_hash.key?(:as)
            parse_str(options_hash[:as]) || parse_sym(options_hash[:as])
          elsif File.basename(template) =~ /\A_?(.*?)(?:\.\w+)*\z/
            $1
          end
        end

        virtual_path = partial_to_virtual_path(render_type, template)
        renders << virtual_path

        # Support for rendering multiple templates (i.e. a partial with a layout)
        if layout_template = render_template_with_layout?(render_type, options_hash)
          virtual_path = partial_to_virtual_path(:layout, layout_template)

          renders << virtual_path
        end

        renders
      end

      def parse_str(node)
        node.string? && node.to_string
      end

      def parse_sym(node)
        node.symbol? && node.to_symbol
      end

      private
        def render_template_with_layout?(render_type, options_hash)
          if render_type != :layout && options_hash.key?(:layout)
            parse_str(options_hash[:layout])
          end
        end

        def render_template_with_spacer?(options_hash)
          if options_hash.key?(:spacer_template)
            parse_str(options_hash[:spacer_template])
          end
        end

        def partial_to_virtual_path(render_type, partial_path)
          if render_type == :partial || render_type == :layout
            partial_path.gsub(%r{(/|^)([^/]*)\z}, '\1_\2')
          else
            partial_path
          end
        end

        def layout_to_virtual_path(layout_path)
          "layouts/#{layout_path}"
        end
  end
end
