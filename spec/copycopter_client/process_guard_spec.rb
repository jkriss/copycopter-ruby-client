require 'spec_helper'

describe CopycopterClient::ProcessGuard do
  include DefinesConstants

  before do
    @original_process_name = $0
  end

  after do
    $0 = @original_process_name
  end

  let(:cache) { stub('cache', :flush => nil) }
  let(:poller) { stub('poller', :start => nil) }

  def build_process_guard(options = {})
    options[:logger] ||= FakeLogger.new
    CopycopterClient::ProcessGuard.new(cache, poller, options)
  end

  it "starts polling from a worker process" do
    process_guard = build_process_guard

    process_guard.start

    poller.should have_received(:start)
  end

  it "registers passenger hooks from the passenger master" do
    logger = FakeLogger.new
    passenger = define_constant('PhusionPassenger', FakePassenger.new)
    passenger.become_master

    process_guard = build_process_guard(:logger => logger)
    process_guard.start

    logger.should have_entry(:info, "Registered Phusion Passenger fork hook")
    poller.should have_received(:start).never
  end

  it "starts polling from a passenger worker" do
    logger = FakeLogger.new
    passenger = define_constant('PhusionPassenger', FakePassenger.new)
    passenger.become_master
    process_guard = build_process_guard(:logger => logger)

    process_guard.start
    passenger.spawn

    poller.should have_received(:start)
  end

  it "registers unicorn hooks from the unicorn master" do
    logger = FakeLogger.new
    define_constant('Unicorn', Module.new)
    http_server = Class.new(FakeUnicornServer)
    unicorn = define_constant('Unicorn::HttpServer', http_server).new
    unicorn.become_master

    process_guard = build_process_guard(:logger => logger)
    process_guard.start

    logger.should have_entry(:info, "Registered Unicorn fork hook")
    poller.should have_received(:start).never
  end

  it "starts polling from a unicorn worker" do
    logger = FakeLogger.new
    define_constant('Unicorn', Module.new)
    http_server = Class.new(FakeUnicornServer)
    unicorn = define_constant('Unicorn::HttpServer', http_server).new
    unicorn.become_master
    process_guard = build_process_guard(:logger => logger)

    process_guard.start
    unicorn.spawn

    poller.should have_received(:start)
  end

  it "flushes when the process terminates" do
    api_key = "12345"
    FakeCopycopterApp.add_project api_key
    pid = fork do
      config = { :logger => FakeLogger.new, :polling_delay => 86400, :api_key => api_key }
      default_config = CopycopterClient::Configuration.new.to_hash.update(config)
      client = CopycopterClient::Client.new(default_config)
      cache = CopycopterClient::Cache.new(client, default_config)
      poller = CopycopterClient::Poller.new(cache, default_config)
      process_guard = CopycopterClient::ProcessGuard.new(cache, poller, default_config)
      process_guard.start
      cache['test.key'] = 'value'
      Signal.trap("INT") { exit }
      sleep
    end
    sleep(0.5)
    Process.kill("INT", pid)
    Process.wait
    project = FakeCopycopterApp.project(api_key)
    project.draft['test.key'].should == 'value'
  end

  it "flushes after running a resque job" do
    define_constant('Resque', Module.new)
    job_class = define_constant('Resque::Job', FakeResqueJob)

    api_key = "12345"
    FakeCopycopterApp.add_project api_key
    logger = FakeLogger.new

    config = { :logger => logger, :polling_delay => 86400, :api_key => api_key }
    default_config = CopycopterClient::Configuration.new.to_hash.update(config)
    client = CopycopterClient::Client.new(default_config)
    cache = CopycopterClient::Cache.new(client, default_config)
    poller = CopycopterClient::Poller.new(cache, default_config)
    job = job_class.new { cache["test.key"] = "expected value" }
    process_guard = CopycopterClient::ProcessGuard.new(cache, poller, default_config)

    process_guard.start

    if fork
      Process.wait
    else
      job.perform
      exit!
    end

    project = FakeCopycopterApp.project(api_key)
    project.draft['test.key'].should == 'expected value'
    logger.should have_entry(:info, "Registered Resque after_perform hook")
  end
end
