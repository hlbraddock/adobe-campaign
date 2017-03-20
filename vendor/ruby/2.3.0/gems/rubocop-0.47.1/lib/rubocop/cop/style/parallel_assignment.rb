# frozen_string_literal: true

require 'tsort'

module RuboCop
  module Cop
    module Style
      # Checks for simple usages of parallel assignment.
      # This will only complain when the number of variables
      # being assigned matched the number of assigning variables.
      #
      # @example
      #   # bad
      #   a, b, c = 1, 2, 3
      #   a, b, c = [1, 2, 3]
      #
      #   # good
      #   one, two = *foo
      #   a, b = foo()
      #   a, b = b, a
      #
      #   a = 1
      #   b = 2
      #   c = 3
      class ParallelAssignment < Cop
        MSG = 'Do not use parallel assignment.'.freeze

        def on_masgn(node)
          lhs, rhs = *node
          lhs_elements = *lhs
          rhs_elements = [*rhs].compact # edge case for one constant

          return if allowed_lhs?(lhs) || allowed_rhs?(rhs) ||
                    allowed_masign?(lhs_elements, rhs_elements)

          add_offense(node, :expression)
        end

        private

        def allowed_masign?(lhs_elements, rhs_elements)
          lhs_elements.size != rhs_elements.size ||
            !find_valid_order(lhs_elements,
                              add_self_to_getters(rhs_elements))
        end

        def allowed_lhs?(node)
          elements = *node

          # Account for edge cases using one variable with a comma
          # E.g.: `foo, = *bar`
          elements.one? || elements.any?(&:splat_type?)
        end

        def allowed_rhs?(node)
          # Edge case for one constant
          elements = [*node].compact

          # Account for edge case of `Constant::CONSTANT`
          !node.array_type? ||
            return_of_method_call?(node) ||
            elements.any?(&:splat_type?)
        end

        def return_of_method_call?(node)
          node.block_type? || node.send_type?
        end

        def autocorrect(node)
          lambda do |corrector|
            left, right = *node
            left_elements = *left
            right_elements = [*right].compact
            order = find_valid_order(left_elements, right_elements)
            correction = assignment_corrector(node, order)

            corrector.replace(correction.correction_range,
                              correction.correction)
          end
        end

        def assignment_corrector(node, order)
          if modifier_statement?(node.parent)
            ModifierCorrector.new(node, config, order)
          elsif rescue_modifier?(node.parent)
            RescueCorrector.new(node, config, order)
          else
            GenericCorrector.new(node, config, order)
          end
        end

        def find_valid_order(left_elements, right_elements)
          # arrange left_elements in an order such that no corresponding right
          # element refers to a left element earlier in the sequence
          # this can be done using an algorithm called a "topological sort"
          # fortunately for us, Ruby's stdlib contains an implementation
          assignments = left_elements.zip(right_elements)

          begin
            AssignmentSorter.new(assignments).tsort
          rescue TSort::Cyclic
            nil
          end
        end

        # Converts (send nil :something) nodes to (send (:self) :something).
        # This makes the sorting algorithm work for expressions such as
        # `self.a, self.b = b, a`.
        def add_self_to_getters(right_elements)
          right_elements.map do |e|
            implicit_self_getter?(e) { |var| s(:send, s(:self), var) } || e
          end
        end

        def_node_matcher :implicit_self_getter?, '(send nil $_)'

        # Helper class necessitated by silly design of TSort prior to Ruby 2.1
        # Newer versions have a better API, but that doesn't help us
        class AssignmentSorter
          include TSort
          extend RuboCop::NodePattern::Macros

          def_node_matcher :var_name, '{(casgn _ $_) (_ $_)}'
          def_node_search :uses_var?, '{({lvar ivar cvar gvar} %) (const _ %)}'
          def_node_search :matching_calls, '(send %1 %2 $...)'

          def initialize(assignments)
            @assignments = assignments
          end

          def tsort_each_node
            @assignments.each { |a| yield a }
          end

          def tsort_each_child(assignment)
            # yield all the assignments which must come after `assignment`
            # (due to dependencies on the previous value of the assigned var)
            my_lhs, _my_rhs = *assignment

            @assignments.each do |other|
              _other_lhs, other_rhs = *other
              if ((var = var_name(my_lhs)) && uses_var?(other_rhs, var)) ||
                 (my_lhs.asgn_method_call? && accesses?(other_rhs, my_lhs))
                yield other
              end
            end
          end

          # `lhs` is an assignment method call like `obj.attr=` or `ary[idx]=`.
          # Does `rhs` access the same value which is assigned by `lhs`?
          def accesses?(rhs, lhs)
            if lhs.method_name == :[]=
              matching_calls(rhs, lhs.receiver, :[]).any? do |args|
                args == lhs.method_args
              end
            else
              access_method = lhs.method_name.to_s.chop.to_sym
              matching_calls(rhs, lhs.receiver, access_method).any?
            end
          end
        end

        def modifier_statement?(node)
          node &&
            ((node.if_type? && node.modifier_form?) ||
            ((node.while_type? || node.until_type?) && modifier_while?(node)))
        end

        def modifier_while?(node)
          node.loc.respond_to?(:keyword) &&
            %w(while until).include?(node.loc.keyword.source) &&
            node.modifier_form?
        end

        def rescue_modifier?(node)
          node && node.rescue_type? &&
            (node.parent.nil? || !(node.parent.kwbegin_type? ||
            node.parent.ensure_type?))
        end

        # An internal class for correcting parallel assignment
        class GenericCorrector
          include AutocorrectAlignment

          attr_reader :config, :node

          def initialize(node, config, new_elements)
            @node = node
            @config = config
            @new_elements = new_elements
          end

          def correction
            assignment.join("\n#{offset(node)}")
          end

          def correction_range
            node.source_range
          end

          protected

          def assignment
            @new_elements.map { |lhs, rhs| "#{lhs.source} = #{source(rhs)}" }
          end

          private

          def source(node)
            if node.str_type? && node.loc.begin.nil?
              "'#{node.source}'"
            elsif node.sym_type? && node.loc.begin.nil?
              ":#{node.source}"
            else
              node.source
            end
          end

          def extract_sources(node)
            node.children.map(&:source)
          end

          def cop_config
            @config.for_cop('Style/ParallelAssignment')
          end
        end

        # An internal class for correcting parallel assignment
        # protected by rescue
        class RescueCorrector < GenericCorrector
          def correction
            _node, rescue_clause = *node.parent
            _, _, rescue_result = *rescue_clause

            # If the parallel assignment uses a rescue modifier and it is the
            # only contents of a method, then we want to make use of the
            # implicit begin
            if node.parent.parent && node.parent.parent.def_type?
              super + def_correction(rescue_result)
            else
              begin_correction(rescue_result)
            end
          end

          def correction_range
            node.parent.source_range
          end

          private

          def def_correction(rescue_result)
            "\nrescue" \
              "\n#{offset(node)}#{rescue_result.source}"
          end

          def begin_correction(rescue_result)
            "begin\n" \
              "#{indentation(node)}" \
              "#{assignment.join("\n#{indentation(node)}")}" \
              "\n#{offset(node)}rescue\n" \
              "#{indentation(node)}#{rescue_result.source}" \
              "\n#{offset(node)}end"
          end
        end

        # An internal class for correcting parallel assignment
        # guarded by if, unless, while, or until
        class ModifierCorrector < GenericCorrector
          def correction
            parent = node.parent

            "#{modifier_range(parent).source}\n" \
              "#{indentation(node)}" \
              "#{assignment.join("\n#{indentation(node)}")}" \
              "\n#{offset(node)}end"
          end

          def correction_range
            node.parent.source_range
          end

          private

          def modifier_range(node)
            Parser::Source::Range.new(node.source_range.source_buffer,
                                      node.loc.keyword.begin_pos,
                                      node.source_range.end_pos)
          end
        end
      end
    end
  end
end