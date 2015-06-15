require 'active_support/inflector'

module RedshiftSimpleMigrator
  class Migrator
    attr_reader :connection, :schema_migrations_table_name
    attr_accessor :migrations_path

    delegate :close, to: :connection

    MIGRATION_FILE_PATTERN = /^(?<version>\d+)_(?<migration_name>.*)\.rb$/.freeze

    def initialize(connection, schema_migrations_table_name = nil)
      @connection = connection
      @schema_migrations_table_name ||= schema_migrations_table_name || "schema_migrations"
    end

    def current_migrations
      return @current_migrations if @current_migrations

      migrations = Dir.entries(migrations_path).map do |name|
        if match = MIGRATION_FILE_PATTERN.match(name)
          load File.expand_path(File.join(migrations_path, name))
          migration_class = match[:migration_name].classify.constantize
          migration_class.new(connection, match[:version].to_i)
        end
      end
      @current_migrations = migrations.compact
    end

    def run_migrations(target_version = nil)
      if direction(target_version) == :up
        migrations = current_migrations.select do |m|
          current_version ? m.version > current_version : true
        end
        migrations.sort_by(&:version)
      else
        migrations = current_migrations.select do |m|
          current_version ? m.version <= current_version : false
        end
        migrations.sort_by {|m| -(m.version) }
      end
    end

    def current_version
      return @current_version if @current_version_is_loaded

      connection.async_exec(get_version_query) do |result|
        versions = result.map do |row|
          row["version"].to_i
        end
        @current_version = versions.max
        @current_version_is_loaded = true
        @current_version
      end
    end

    def run(target_version = nil)
      connection.with_transaction do
        run_migrations(target_version).each do |m|
          d = direction(target_version)
          p d
          m.send(d)
          if d == :up
            insert_version(m.version)
          else
            remove_version(m.version)
          end
        end
      end
    end

    private

    def get_version_query
      "SELECT version FROM #{connection.escape_identifier(schema_migrations_table_name)}"
    end

    def direction(target_version)
      return :up unless target_version && current_version

      if current_version.to_i <= target_version.to_i
        :up
      else
        :down
      end
    end

    def insert_version(version)
      connection.exec_params(<<-SQL, [version.to_s])
      INSERT INTO #{connection.escape_identifier(schema_migrations_table_name)} (version) VALUES ($1)
      SQL
    end

    def remove_version(version)
      connection.exec_params(<<-SQL, [version.to_s])
      DELETE FROM #{connection.escape_identifier(schema_migrations_table_name)} WHERE version = $1
      SQL
    end
  end
end