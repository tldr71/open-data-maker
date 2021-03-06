module DataMagic
  module Index
    class Repository
      attr_reader :client, :document

      def initialize(client, document)
        @client = client
        @document = document
      end

      def skipped?
        @skipped
      end

      def save
        @skipped = false
        if client.creating?
          create
        else
          update
        end
      end

      private

      def update
        if client.allow_skips?
          update_with_rescue
        else
          update_without_rescue
        end
      end

      def create
        client.index({
          index: client.index_name,
          id: document.id,
          type: 'document',
          body: document.data,
          timeout: '5m'
        })
      end

      def update_without_rescue
        if client.nested_partial?
          update_nested_partial
        else
          client.update({
              index: client.index_name,
              id: document.id,
              type: 'document',
              body: {doc: document.data},
              timeout: '5m'
          })
        end
      end

      def update_with_rescue
        update_without_rescue
      rescue Elasticsearch::Transport::Transport::Errors::NotFound
        @skipped = true
      end

      def update_nested_partial
        if document.is_a?(Array)
          update_bulk_nested_partial
        else
        doc = {
            index: client.index_name,
            id: document.id,
            type: 'document',
            body: {doc: document.data},
            timeout: '5m'
        }
        root_key = client.options[:nest]['key']
        partial_path =  client.options[:partial_map]['path']

        # extract some keys of the dotted path
        path_keys = partial_path.split('.')
        first = path_keys.first
        path_keys = path_keys.unshift(root_key)

        # extract the current row's nested data, in the case we're appending to an exiting array
        nested_item = document.data.dig(*path_keys)[0]

        # this script will either create the new nested array if it doesn't exist, or append the nested item
        script = "if (ctx._source['#{root_key}'].#{first} == null) { ctx._source['#{root_key}'].#{first} = data['#{root_key}'].#{first}; } else { ctx._source['#{root_key}'].#{partial_path} += inner; }"
        doc[:body] = { script: script, params: { inner: nested_item, data: document.data } }
        doc[:retry_on_conflict] = 5
        client.update(doc)
        end
      end

      def update_bulk_nested_partial
        root_key = client.options[:nest]['key']
        partial_path =  client.options[:partial_map]['path']

        # extract some keys of the dotted path
        path_keys = partial_path.split('.')
        first = path_keys.first
        path_keys = path_keys.unshift(root_key)

        nested_items = document.map do |doc|
          doc.data.dig(*path_keys)[0]
        end

        hash = NestedHash.new
        hash.dotkey_set(path_keys.join('.'), nested_items)

        doc = {
            index: client.index_name,
            id: document[0].id,
            type: 'document',
            timeout: '5m'
        }
        # this script will either create the full object path and new nested array if it doesn't exist already, or create the new nested items array
        script = "if (ctx._source['#{root_key}'] == null) { ctx._source['#{root_key}'] = data['#{root_key}']; } else { if (ctx._source['#{root_key}'].#{first} == null) { ctx._source['#{root_key}'].#{first} = data['#{root_key}'].#{first}; } else { ctx._source['#{root_key}'].#{partial_path} = inner; } }"
        doc[:body] = { script: script, params: { inner: nested_items, data: hash } }
        doc[:retry_on_conflict] = 5
        client.update(doc)
      end
    end
  end
end
