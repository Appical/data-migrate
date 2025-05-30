# frozen_string_literal: true

require "data_migrate/config"

module DataMigrate
  ##
  # This class extends DatabaseTasks to add a schema_file method.
  module DatabaseTasks
    extend ActiveRecord::Tasks::DatabaseTasks
    extend self

    # These method are only introduced in Rails 7.1
    unless respond_to?(:with_temporary_connection_for_each)
      def with_temporary_connection_for_each(env: ActiveRecord::Tasks::DatabaseTasks.env, name: nil, &block) # :nodoc:
        if name
          db_config = ActiveRecord::Base.configurations.configs_for(env_name: env, name: name)
          with_temporary_connection(db_config, &block)
        else
          ActiveRecord::Base.configurations.configs_for(env_name: env, name: name).each do |db_config|
            with_temporary_connection(db_config, &block)
          end
        end
      end

      def with_temporary_connection(db_config) # :nodoc:
        with_temporary_pool(db_config) do |pool|
          yield pool.connections.first
        end
      end

      def migration_class # :nodoc:
        ActiveRecord::Base
      end

      def migration_connection # :nodoc:
        migration_class.connection
      end

      private def with_temporary_pool(db_config)
        original_db_config = migration_class.connection_db_config
        pool = migration_class.connection_handler.establish_connection(db_config)

        yield pool
      ensure
        migration_class.connection_handler.establish_connection(original_db_config)
      end
    end

    def db_configs_with_versions
      db_configs_with_versions = Hash.new { |h, k| h[k] = [] }

      with_temporary_connection_for_each do |conn|
        db_config = conn.pool.db_config
        if db_config.primary?
          versions_to_run = DataMigrate::DatabaseTasks.pending_data_migrations.map { |m| m[:version] }
          target_version = ActiveRecord::Tasks::DatabaseTasks.target_version

          versions_to_run.each do |version|
            next if target_version && target_version != version
            db_configs_with_versions[version] << DatabaseConfigurationWrapper.new(db_config)
          end
        end
      end

      db_configs_with_versions
    end

    def schema_file(_format = nil)
      File.join(db_dir, "data_schema.rb")
    end

    def schema_file_type(_format = nil)
      "data_schema.rb"
    end

    # This method is removed in Rails 7.0
    def dump_filename(spec_name, format = ActiveRecord::Base.schema_format)
      filename = if spec_name == "primary"
        schema_file_type(format)
      else
        "#{spec_name}_#{schema_file_type(format)}"
      end

      ENV["DATA_SCHEMA"] || File.join(db_dir, filename)
    end

    def check_schema_file(filename)
      unless File.exist?(filename)
        message = +%{#{filename} doesn't exist yet. Run `rake data:migrate` to create it, then try again.}
        Kernel.abort message
      end
    end

    def pending_migrations
      sort_migrations(
        pending_schema_migrations,
        pending_data_migrations
      )
    end

    def sort_migrations(*migrations)
      migrations.flatten.sort { |a, b|  sort_string(a) <=> sort_string(b) }
    end

    def sort_string migration
      "#{migration[:version]}_#{migration[:kind] == :data ? 1 : 0}"
    end

    def data_migrations_path
      ::DataMigrate.config.data_migrations_path
    end

    def run_migration(migration, direction)
      if migration[:kind] == :data
        ::ActiveRecord::Migration.write("== %s %s" % ['Data', "=" * 71])
        ::DataMigrate::DataMigrator.run(direction, data_migrations_path, migration[:version])
      else
        ::ActiveRecord::Migration.write("== %s %s" % ['Schema', "=" * 69])
        ::DataMigrate::SchemaMigration.run(
          direction,
          ::DataMigrate::SchemaMigration.migrations_paths,
          migration[:version]
        )
      end
    end

    def schema_dump_path(db_config, format = ActiveRecord.schema_format)
      return ENV["DATA_SCHEMA"] if ENV["DATA_SCHEMA"]

      # We only require a schema.rb file for the primary database
      return unless db_config.primary?

      File.join(File.dirname(ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(db_config, format)), schema_file_type)
    end

    # Override this method from `ActiveRecord::Tasks::DatabaseTasks`
    # to ensure that the sha saved in ar_internal_metadata table
    # is from the original schema.rb file
    def schema_sha1(file)
      ActiveRecord::Tasks::DatabaseTasks.schema_dump_path(ActiveRecord::Base.configurations.configs_for(env_name: ActiveRecord::Tasks::DatabaseTasks.env, name: "primary"))
    end

    def forward(step = 1)
      DataMigrate::DataMigrator.create_data_schema_table
      migrations = pending_migrations.reverse.pop(step).reverse
      migrations.each do | pending_migration |
        if pending_migration[:kind] == :data
          ActiveRecord::Migration.write("== %s %s" % ["Data", "=" * 71])
          DataMigrate::DataMigrator.run(:up, data_migrations_path, pending_migration[:version])
        elsif pending_migration[:kind] == :schema
          ActiveRecord::Migration.write("== %s %s" % ["Schema", "=" * 69])
          DataMigrate::SchemaMigration.run(:up, DataMigrate::SchemaMigration.migrations_paths, pending_migration[:version])
        end
      end
    end

    def pending_data_migrations
      data_migrations = DataMigrate::DataMigrator.migrations(data_migrations_path)
      data_migrator = DataMigrate::RailsHelper.data_migrator(:up, data_migrations)
      sort_migrations(
        data_migrator.pending_migrations.map { |m| { version: m.version, name: m.name, kind: :data } }
        )
    end

    def pending_schema_migrations
      ::DataMigrate::SchemaMigration.pending_schema_migrations
    end

    def past_migrations(sort = nil)
      data_versions = DataMigrate::RailsHelper.data_schema_migration.table_exists? ? DataMigrate::RailsHelper.data_schema_migration.normalized_versions : []
      schema_versions = DataMigrate::RailsHelper.schema_migration.normalized_versions
      migrations = data_versions.map { |v| { version: v.to_i, kind: :data } } + schema_versions.map { |v| { version: v.to_i, kind: :schema } }

      sort&.downcase == "asc" ? sort_migrations(migrations) : sort_migrations(migrations).reverse
    end
  end
end
