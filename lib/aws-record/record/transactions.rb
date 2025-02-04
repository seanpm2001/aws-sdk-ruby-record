# frozen_string_literal: true

module Aws
  module Record
    module Transactions
      extend ClientConfiguration

      class << self
        # @example Usage Example
        #   class TableOne
        #     include Aws::Record
        #     string_attr :uuid, hash_key: true
        #   end
        #
        #   class TableTwo
        #     include Aws::Record
        #     string_attr :hk, hash_key: true
        #     string_attr :rk, range_key: true
        #   end
        #
        #   results = Aws::Record::Transactions.transact_find(
        #     transact_items: [
        #       TableOne.tfind_opts(key: { uuid: "uuid1234" }),
        #       TableTwo.tfind_opts(key: { hk: "hk1", rk: "rk1"}),
        #       TableTwo.tfind_opts(key: { hk: "hk2", rk: "rk2"})
        #     ]
        #   ) # => results.responses contains nil or marshalled items
        #   results.responses.map { |r| r.class } # [TableOne, TableTwo, TableTwo]
        #
        # Provides support for the
        # {https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/DynamoDB/Client.html#transact_get_items-instance_method
        # Aws::DynamoDB::Client#transact_get_item} for aws-record models.
        #
        # This method runs a transactional find across multiple DynamoDB
        # items, including transactions which get items across multiple actual
        # or virtual tables. This call can contain up to 100 item keys.
        #
        # DynamoDB will reject the request if any of the following is true:
        # * A conflicting operation is in the process of updating an item to be read.
        # * There is insufficient provisioned capacity for the transaction to be completed.
        # * There is a user error, such as an invalid data format.
        # * The aggregate size of the items in the transaction cannot exceed 4 MB.
        #
        # @param [Hash] opts Options to pass through to
        #   {https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/DynamoDB/Client.html#transact_get_items-instance_method
        #   Aws::DynamoDB::Client#transact_get_items}, with the exception of the
        #   +:transact_items+ array, which uses the {ItemOperations.ItemOperationsClassMethods.tfind_opts #tfind_opts}
        #   operation on your model class to provide extra metadata
        #   used to marshal your items after retrieval.
        # @option opts [Array] :transact_items A set of +#tfind_opts+ results,
        #   such as those created by the usage example.
        # @option opts [Aws::DynamoDB::Client] :client Optionally, you can pass
        #   in your own client to use for the transaction calls.
        # @return [OpenStruct] Structured like the client API response from
        #   +#transact_get_items+, except that the +responses+ member contains
        #   +Aws::Record+ items marshaled into the classes used to call
        #   +#tfind_opts+ in each positional member. See the usage example.
        def transact_find(opts)
          opts = opts.dup
          client = opts.delete(:client) || dynamodb_client
          transact_items = opts.delete(:transact_items) # add nil check?
          model_classes = []
          client_transact_items = transact_items.map do |tfind_opts|
            model_class = tfind_opts.delete(:model_class)
            model_classes << model_class
            tfind_opts
          end
          request_opts = opts
          request_opts[:transact_items] = client_transact_items
          client_resp = client.transact_get_items(
            request_opts
          )
          index = -1
          ret = OpenStruct.new
          ret.consumed_capacity = client_resp.consumed_capacity
          ret.missing_items = []
          ret.responses = client_resp.responses.map do |item|
            index += 1
            if item.nil? || item.item.nil?
              missing_data = {
                model_class: model_classes[index],
                key: transact_items[index][:get][:key]
              }
              ret.missing_items << missing_data
              nil
            else
              # need to translate the item keys
              raw_item = item.item
              model_class = model_classes[index]
              new_item_opts = {}
              raw_item.each do |db_name, value|
                name = model_class.attributes.db_to_attribute_name(db_name)
                new_item_opts[name] = value
              end
              item = model_class.new(new_item_opts)
              item.clean!
              item
            end
          end
          ret
        end

        # @example Usage Example
        #   class TableOne
        #     include Aws::Record
        #     string_attr :uuid, hash_key: true
        #     string_attr :body
        #   end
        #
        #   class TableTwo
        #     include Aws::Record
        #     string_attr :hk, hash_key: true
        #     string_attr :rk, range_key: true
        #     string_attr :body
        #   end
        #
        #   check_exp = TableOne.transact_check_expression(
        #     key: { uuid: "foo" },
        #     condition_expression: "size(#T) <= :v",
        #     expression_attribute_names: {
        #       "#T" => "body"
        #     },
        #     expression_attribute_values: {
        #       ":v" => 1024
        #     }
        #   )
        #   new_item = TableTwo.new(hk: "hk1", rk: "rk1", body: "Hello!")
        #   update_item_1 = TableOne.find(uuid: "bar")
        #   update_item_1.body = "Updated the body!"
        #   put_item = TableOne.new(uuid: "foobar", body: "Content!")
        #   update_item_2 = TableTwo.find(hk: "hk2", rk: "rk2")
        #   update_item_2.body = "Update!"
        #   delete_item = TableOne.find(uuid: "to_be_deleted")
        #
        #   Aws::Record::Transactions.transact_write(
        #     transact_items: [
        #       { check: check_exp },
        #       { save: new_item },
        #       { save: update_item_1 },
        #       {
        #          put: put_item,
        #          condition_expression: "attribute_not_exists(#H)",
        #          expression_attribute_names: { "#H" => "uuid" },
        #          return_values_on_condition_check_failure: "ALL_OLD"
        #       },
        #       { update: update_item_2 },
        #       { delete: delete_item }
        #     ]
        #   )
        #
        # Provides support for the
        # {https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/DynamoDB/Client.html#transact_write_items-instance_method
        # Aws::DynamoDB::Client#transact_write_items} for aws-record models.
        #
        # This method passes in aws-record items into transactional writes,
        # as well as adding the ability to run 'save' commands in a transaction
        # while allowing aws-record to determine if a :put or :update operation
        # is most appropriate. +#transact_write+ supports 5 different transact
        # item modes:
        # - save: Behaves much like the +#save+ operation on the item itself.
        #   If the keys are dirty, and thus it appears to be a new item, will
        #   create a :put operation with a conditional check on the item's
        #   existence. Note that you cannot bring your own conditional
        #   expression in this case. If you wish to force put or add your
        #   own conditional checks, use the :put operation.
        # - put: Does a force put for the given item key and model.
        # - update: Does an upsert for the given item.
        # - delete: Deletes the given item.
        # - check: Takes the result of +#transact_check_expression+,
        #   performing the specified check as a part of the transaction.
        #   See {ItemOperations.ItemOperationsClassMethods.transact_check_expression #transact_check_expression}
        #   for more information.
        #
        # This call contain up to 100 action requests.
        #
        # DynamoDB will reject the request if any of the following is true:
        # * A condition in one of the condition expressions is not met.
        # * An ongoing operation is in the process of updating the same item.
        # * There is insufficient provisioned capacity for the transaction to
        #   be completed.
        # * An item size becomes too large (bigger than 400 KB), a local secondary
        #   index (LSI) becomes too large, or a similar validation error occurs
        #   because of changes made by the transaction.
        # * The aggregate size of the items in the transaction exceeds 4 MB.
        # * There is a user error, such as an invalid data format.
        #
        # @param [Hash] opts Options to pass through to
        #   {https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/DynamoDB/Client.html#transact_write_items-instance_method
        #   Aws::DynamoDB::Client#transact_write_items} with the exception of
        #   :transact_items array, which is transformed to use your item to populate
        #   the :key, :table_name, :item, and/or :update_expression parameters
        #   as appropriate. See the usage example for a comprehensive set of combinations.
        # @option opts [Array] :transact_items An array of hashes, accepting
        #   +:save+, +:put+, +:delete+, +:update+, and +:check+ as specified.
        # @option opts [Aws::DynamoDB::Client] :client Optionally, you can
        #   specify a client to use for this transaction call. If not
        #   specified, the configured client for +Aws::Record::Transactions+
        #   is used.
        def transact_write(opts)
          opts = opts.dup
          client = opts.delete(:client) || dynamodb_client
          dirty_items = []
          delete_items = []
          # fetch abstraction records
          transact_items = _transform_transact_write_items(
            opts.delete(:transact_items),
            dirty_items,
            delete_items
          )
          opts[:transact_items] = transact_items
          resp = client.transact_write_items(opts)
          # mark all items clean/destroyed as needed if we didn't raise an exception
          dirty_items.each(&:clean!)
          delete_items.each { |i| i.instance_variable_get('@data').destroyed = true }
          resp
        end

        private

        def _transform_transact_write_items(transact_items, dirty_items, delete_items)
          transact_items.map do |item|
            # this code will assume users only provided one operation, and
            # will fail down the line if that assumption is wrong
            if (save_record = item.delete(:save))
              dirty_items << save_record
              _transform_save_record(save_record, item)
            elsif (put_record = item.delete(:put))
              dirty_items << put_record
              _transform_put_record(put_record, item)
            elsif (delete_record = item.delete(:delete))
              delete_items << delete_record
              _transform_delete_record(delete_record, item)
            elsif (update_record = item.delete(:update))
              dirty_items << update_record
              _transform_update_record(update_record, item)
            elsif (check_record = item.delete(:check))
              _transform_check_record(check_record, item)
            else
              raise ArgumentError, 'Invalid transact write item, must include an operation of '\
                                   "type :save, :update, :delete, :update, or :check - #{item}"

            end
          end
        end

        def _transform_save_record(save_record, opts)
          # determine if record is considered a new item or not
          # then create a put with conditions, or an update
          if save_record.send(:expect_new_item?)
            safety_expression = save_record.send(:prevent_overwrite_expression)
            if opts.include?(:condition_expression)
              raise Errors::TransactionalSaveConditionCollision,
                    'Transactional write includes a :save operation that would '\
                    "result in a 'safe put' for the given item, yet a "\
                    'condition expression was also provided. This is not '\
                    'currently supported. You should rewrite this case to use '\
                    'a :put transaction, adding the existence check to your '\
                    "own condition expression if desired.\n"\
                    "\tItem: #{JSON.pretty_unparse(save_record.to_h)}\n"\
                    "\tExtra Options: #{JSON.pretty_unparse(opts)}"
            else
              opts = opts.merge(safety_expression)
              _transform_put_record(save_record, opts)
            end
          else
            _transform_update_record(save_record, opts)
          end
        end

        def _transform_put_record(put_record, opts)
          # convert to a straight put
          opts[:table_name] = put_record.class.table_name
          opts[:item] = put_record.send(:_build_item_for_save)
          { put: opts }
        end

        def _transform_delete_record(delete_record, opts)
          # extract the key from each record to perform a deletion
          opts[:table_name] = delete_record.class.table_name
          opts[:key] = delete_record.send(:key_values)
          { delete: opts }
        end

        def _transform_update_record(update_record, opts)
          # extract dirty attribute changes to perform an update
          opts[:table_name] = update_record.class.table_name
          dirty_changes = update_record.send(:_dirty_changes_for_update)
          update_tuple = update_record.class.send(
            :_build_update_expression,
            dirty_changes
          )
          uex, exp_attr_names, exp_attr_values = update_tuple
          opts[:key] = update_record.send(:key_values)
          opts[:update_expression] = uex
          # need to combine expression attribute names and values
          if (names = opts[:expression_attribute_names])
            opts[:expression_attribute_names] = exp_attr_names.merge(names)
          else
            opts[:expression_attribute_names] = exp_attr_names
          end
          if (values = opts[:expression_attribute_values])
            opts[:expression_attribute_values] = exp_attr_values.merge(values)
          else
            opts[:expression_attribute_values] = exp_attr_values
          end
          { update: opts }
        end

        def _transform_check_record(check_record, opts)
          # check records are a pass-through
          { condition_check: opts.merge(check_record) }
        end
      end
    end
  end
end
