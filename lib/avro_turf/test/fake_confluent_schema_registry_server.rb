require 'sinatra/base'

class FakeConfluentSchemaRegistryServer < Sinatra::Base
  SUBJECTS = Hash.new { Array.new }
  SCHEMAS = []
  CONFIGS = Hash.new
  SUBJECT_NOT_FOUND = { error_code: 40401, message: 'Subject not found' }.to_json.freeze
  VERSION_NOT_FOUND = { error_code: 40402, message: 'Version not found' }.to_json.freeze
  SCHEMA_NOT_FOUND = { error_code: 40403, message: 'Schema not found' }.to_json.freeze
  DEFAULT_GLOBAL_CONFIG = { 'compatibility' => 'BACKWARD'.freeze }.freeze

  @global_config = DEFAULT_GLOBAL_CONFIG.dup

  class << self
    attr_reader :global_config
  end

  helpers do
    def parse_schema
      request.body.rewind
      JSON.parse(request.body.read).fetch("schema").tap do |schema|
        Avro::Schema.parse(schema)
      end
    end

    def parse_config
      request.body.rewind
      JSON.parse(request.body.read)
    end

    def global_config
      self.class.global_config
    end
  end

  post "/subjects/:subject/versions" do
    schema = parse_schema
    schema_id = SCHEMAS.index(schema)
    if schema_id.nil?
      SCHEMAS << schema
      schema_id = SCHEMAS.size - 1
    end

    subject = params[:subject]
    unless SUBJECTS[subject].include?(schema_id)
      SUBJECTS[subject] = SUBJECTS[subject] << schema_id
    end

    { id: schema_id }.to_json
  end

  get "/schemas/ids/:schema_id/versions" do
    schema_id = params[:schema_id].to_i
    schema = SCHEMAS.at(schema_id)
    halt(404, SCHEMA_NOT_FOUND) unless schema

    related_subjects = SUBJECTS.select {|_, vs| vs.include? schema_id }

    related_subjects.map do |subject, versions|
      {
        subject: subject,
        version: versions.find_index(schema_id) + 1
      }
    end.to_json
  end

  get "/schemas/ids/:schema_id" do
    schema = SCHEMAS.at(params[:schema_id].to_i)
    halt(404, SCHEMA_NOT_FOUND) unless schema
    { schema: schema }.to_json
  end

  get "/subjects" do
    SUBJECTS.keys.to_json
  end

  get "/subjects/:subject/versions" do
    schema_ids = SUBJECTS[params[:subject]]
    halt(404, SUBJECT_NOT_FOUND) if schema_ids.empty?
    (1..schema_ids.size).to_a.to_json
  end

  get "/subjects/:subject/versions/:version" do
    schema_ids = SUBJECTS[params[:subject]]
    halt(404, SUBJECT_NOT_FOUND) if schema_ids.empty?

    schema_id = if params[:version] == 'latest'
                  schema_ids.last
                else
                  schema_ids.at(Integer(params[:version]) - 1)
                end
    halt(404, VERSION_NOT_FOUND) unless schema_id

    schema = SCHEMAS.at(schema_id)

    {
      name: params[:subject],
      version: schema_ids.index(schema_id) + 1,
      id: schema_id,
      schema: schema
    }.to_json
  end

  post "/subjects/:subject" do
    schema = parse_schema

    # Note: this does not actually handle the same schema registered under
    # multiple subjects
    schema_id = SCHEMAS.index(schema)

    halt(404, SCHEMA_NOT_FOUND) unless schema_id

    {
      subject: params[:subject],
      id: schema_id,
      version: SUBJECTS[params[:subject]].index(schema_id) + 1,
      schema: schema
    }.to_json
  end

  post "/compatibility/subjects/:subject/versions/:version" do
    # The ruby avro gem does not yet include a compatibility check between schemas.
    # See https://github.com/apache/avro/pull/170
    raise NotImplementedError
  end

  get "/config" do
    global_config.to_json
  end

  put "/config" do
    global_config.merge!(parse_config).to_json
  end

  get "/config/:subject" do
    CONFIGS.fetch(params[:subject], global_config).to_json
  end

  put "/config/:subject" do
    config = parse_config
    subject = params[:subject]
    CONFIGS.fetch(subject) do
      CONFIGS[subject] = {}
    end.merge!(config).to_json
  end

  def self.clear
    SUBJECTS.clear
    SCHEMAS.clear
    CONFIGS.clear
    @global_config = DEFAULT_GLOBAL_CONFIG.dup
  end
end
