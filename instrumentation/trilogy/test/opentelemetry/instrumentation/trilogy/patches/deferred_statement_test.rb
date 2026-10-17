# frozen_string_literal: true

# Copyright The OpenTelemetry Authors
#
# SPDX-License-Identifier: Apache-2.0

require 'test_helper'

# Exercise the installed patch and real SDK spans without a database connection.
describe 'Trilogy deferred SQL obfuscation' do
  class StatementDriver
    attr_reader :connection_options, :queries
    attr_accessor :query_error

    def initialize(options)
      @connection_options = options
      @queries = []
    end

    def query(sql)
      @queries << sql
      raise query_error if query_error

      :result
    end
  end

  let(:instrumentation) { OpenTelemetry::Instrumentation::Trilogy::Instrumentation.instance }
  let(:config) { { db_statement: :obfuscate_when_recording } }
  let(:decision) { OpenTelemetry::SDK::Trace::Samplers::Decision::RECORD_AND_SAMPLE }
  let(:sampling_result) { OpenTelemetry::SDK::Trace::Samplers::Result.new(decision: decision, tracestate: OpenTelemetry::Trace::Tracestate::DEFAULT) }
  let(:sampler) { double('sampler', should_sample?: sampling_result, description: 'test') }
  let(:spans) { [] }
  let(:initial_attributes) { [] }
  let(:provider) do
    processor = double('processor', on_start: nil, on_finish: nil)
    allow(processor).to receive(:on_start) { |span, _parent| initial_attributes << span.attributes.dup }
    allow(processor).to receive(:on_finish) { |span| spans << span.to_span_data }
    OpenTelemetry::SDK::Trace::TracerProvider.new(sampler: sampler).tap { |p| p.add_span_processor(processor) }
  end
  let(:statement_keys) do
    {
      old: ['db.statement'],
      stable: ['db.query.text'],
      dup: ['db.statement', 'db.query.text']
    }.fetch(instrumentation.semconv)
  end
  let(:client) do
    patch = OpenTelemetry::Instrumentation::Trilogy::Patches.const_get(instrumentation.semconv.to_s.capitalize)::Client
    Class.new(StatementDriver).tap { |driver| driver.prepend(patch) }.new(host: 'db.example.com', database: 'myapp', username: 'app')
  end

  before do
    skip unless defined?(Trilogy)

    instrumentation.instance_variable_set(:@installed, false)
    instrumentation.install(config)
    @original_tracer = instrumentation.tracer
    instrumentation.instance_variable_set(:@tracer, provider.tracer('deferred-statement-test'))
    client
    spans.clear
    initial_attributes.clear
  end

  after do
    instrumentation.instance_variable_set(:@tracer, @original_tracer) if @original_tracer
    instrumentation.instance_variable_set(:@installed, false)
  end

  it 'accepts the deferred option' do
    _(instrumentation.config[:db_statement]).must_equal :obfuscate_when_recording
  end

  it 'obfuscates once after sampling while retaining connection attributes at span start' do
    expect(OpenTelemetry::Helpers::SqlProcessor).to receive(:obfuscate_sql).once.and_call_original
    expect(sampler).to receive(:should_sample?) do |**args|
      _(args[:kind]).must_equal :client
      _(args[:attributes].values).must_include 'mysql'
      _(args[:attributes].values).must_include 'db.example.com'
      _(args[:attributes].values).must_include 'myapp'
      statement_keys.each { |key| refute args[:attributes].key?(key) }
      sampling_result
    end

    _(client.query('SELECT 42')).must_equal :result

    statement_keys.each do |key|
      refute initial_attributes.last.key?(key)
      _(spans.last.attributes[key]).must_equal 'SELECT ?'
    end
  end

  it 'preserves contextual statement overrides without obfuscating' do
    overrides = statement_keys.to_h { |key| [key, "override #{key}"] }
    expect(OpenTelemetry::Helpers::SqlProcessor).not_to receive(:obfuscate_sql)

    OpenTelemetry::Instrumentation::Trilogy.with_attributes(overrides) { client.query('SELECT 42') }

    overrides.each do |key, value|
      _(initial_attributes.last[key]).must_equal value
      _(spans.last.attributes[key]).must_equal value
    end
  end

  it 'preserves a partial override when emitting both conventions' do
    skip unless instrumentation.semconv == :dup

    expect(OpenTelemetry::Helpers::SqlProcessor).to receive(:obfuscate_sql).once.and_call_original
    OpenTelemetry::Instrumentation::Trilogy.with_attributes('db.statement' => 'override') { client.query('SELECT 42') }

    _(spans.last.attributes['db.statement']).must_equal 'override'
    _(spans.last.attributes['db.query.text']).must_equal 'SELECT ?'
  end

  it 'retains the obfuscation limit' do
    client.query("SELECT #{'1,' * 1000}")

    statement_keys.each { |key| _(spans.last.attributes[key]).must_equal 'SQL not obfuscated, query exceeds 2000 characters' }
  end

  it 'retains safe output for malformed SQL' do
    client.query("SELECT 'private")

    statement_keys.each { |key| _(spans.last.attributes[key]).must_equal 'Failed to obfuscate SQL query - quote characters remained after obfuscation' }
  end

  it 'retains statement and exception evidence for failed queries' do
    client.query_error = Trilogy::ProtocolError.new('query failed')

    _(-> { client.query('SELECT 42') }).must_raise Trilogy::Error

    statement_keys.each { |key| _(spans.last.attributes[key]).must_equal 'SELECT ?' }
    _(spans.last.status.code).must_equal OpenTelemetry::Trace::Status::ERROR
    _(spans.last.events.last.name).must_equal 'exception'
    _(spans.last.attributes['error.type']).must_equal 'Trilogy::ProtocolError' unless instrumentation.semconv == :old
  end

  it 'does not enrich a recording parent reused by a tracer' do
    parent = provider.tracer('parent-test').start_span('parent')
    allow(instrumentation.tracer).to receive(:start_span).and_return(parent)
    expect(OpenTelemetry::Helpers::SqlProcessor).not_to receive(:obfuscate_sql)

    OpenTelemetry::Trace.with_span(parent) { client.query('SELECT 42') }

    statement_keys.each { |key| refute parent.attributes.key?(key) }
    _(client.queries.last).must_equal 'SELECT 42'
  end

  describe 'with default options' do
    let(:config) { {} }

    it 'keeps statements visible to samplers and start processors' do
      expect(sampler).to receive(:should_sample?) do |**args|
        statement_keys.each { |key| _(args[:attributes][key]).must_equal 'SELECT ?' }
        sampling_result
      end

      client.query('SELECT 42')

      statement_keys.each { |key| _(initial_attributes.last[key]).must_equal 'SELECT ?' }
    end
  end

  describe 'when the sampler drops the span' do
    let(:decision) { OpenTelemetry::SDK::Trace::Samplers::Decision::DROP }

    it 'executes the query without obfuscating SQL' do
      sql = 'SELECT 42'
      expect(OpenTelemetry::Helpers::SqlProcessor).not_to receive(:obfuscate_sql)

      _(client.query(sql)).must_equal :result

      assert_same sql, client.queries.last
      _(spans).must_be_empty
    end
  end

  describe 'when the sampler records without sampling' do
    let(:decision) { OpenTelemetry::SDK::Trace::Samplers::Decision::RECORD_ONLY }

    it 'retains obfuscated statements' do
      client.query('SELECT 42')

      statement_keys.each { |key| _(spans.last.attributes[key]).must_equal 'SELECT ?' }
      refute_predicate spans.last.trace_flags, :sampled?
    end
  end

  describe 'with Vitess propagation' do
    let(:config) { { db_statement: :obfuscate_when_recording, propagator: 'vitess' } }

    it 'obfuscates before injecting context into a copy of frozen SQL' do
      sql = 'SELECT 42'

      client.query(sql)

      _(sql).must_equal 'SELECT 42'
      assert_predicate sql, :frozen?
      refute_same sql, client.queries.last
      assert_predicate client.queries.last, :frozen?
      _(client.queries.last).must_include '/*VT_SPAN_CONTEXT='
      statement_keys.each { |key| _(spans.last.attributes[key]).must_equal 'SELECT ?' }
    end

    it 'injects context into mutable SQL' do
      sql = +'SELECT 42'

      client.query(sql)

      assert_same sql, client.queries.last
      _(sql).must_include '/*VT_SPAN_CONTEXT='
      statement_keys.each { |key| _(spans.last.attributes[key]).must_equal 'SELECT ?' }
    end

    describe 'when the sampler drops the span' do
      let(:decision) { OpenTelemetry::SDK::Trace::Samplers::Decision::DROP }

      it 'propagates without obfuscating' do
        sql = 'SELECT 42'
        expect(OpenTelemetry::Helpers::SqlProcessor).not_to receive(:obfuscate_sql)

        _(client.query(sql)).must_equal :result

        _(sql).must_equal 'SELECT 42'
        _(client.queries.last).must_include '/*VT_SPAN_CONTEXT='
      end
    end
  end
end
