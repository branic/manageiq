describe ManageIQ::Providers::AnsibleRoleWorkflow do
  let(:job)          { described_class.create_job(*options).tap { |job| job.state = state } }
  let(:role_options) { {:role_name => 'role_name', :roles_path => 'path/role', :role_skip_facts => true } }
  let(:options)      { [{"ENV" => "VAR"}, {"arg1" => "val1"}, role_options, {:verbosity => 4}] }
  let(:state)        { "waiting_to_start" }

  context ".create_job" do
    it "leaves job waiting to start" do
      expect(job.state).to eq("waiting_to_start")
    end
  end

  context ".signal" do
    %w[start pre_execute execute poll_runner post_execute finish abort_job cancel error].each do |signal|
      shared_examples_for "allows #{signal} signal" do
        it signal.to_s do
          expect(job).to receive(signal.to_sym)
          job.signal(signal.to_sym)
        end
      end
    end

    %w[start pre_execute execute poll_runner post_execute].each do |signal|
      shared_examples_for "doesn't allow #{signal} signal" do
        it signal.to_s do
          expect { job.signal(signal.to_sym) }.to raise_error(RuntimeError, /#{signal} is not permitted at state #{job.state}/)
        end
      end
    end

    context "waiting_to_start" do
      let(:state) { "waiting_to_start" }

      it_behaves_like "allows start signal"
      it_behaves_like "allows finish signal"
      it_behaves_like "allows abort_job signal"
      it_behaves_like "allows cancel signal"
      it_behaves_like "allows error signal"

      it_behaves_like "doesn't allow execute signal"
      it_behaves_like "doesn't allow poll_runner signal"
      it_behaves_like "doesn't allow post_execute signal"
    end

    context "per_role" do
      let(:state) { "pre_execute" }

      it_behaves_like "allows execute signal"
      it_behaves_like "allows finish signal"
      it_behaves_like "allows abort_job signal"
      it_behaves_like "allows cancel signal"
      it_behaves_like "allows error signal"

      it_behaves_like "doesn't allow start signal"
      it_behaves_like "doesn't allow poll_runner signal"
      it_behaves_like "doesn't allow post_execute signal"
    end

    context "running" do
      let(:state) { "running" }

      it_behaves_like "allows poll_runner signal"
      it_behaves_like "allows finish signal"
      it_behaves_like "allows abort_job signal"
      it_behaves_like "allows cancel signal"
      it_behaves_like "allows error signal"

      it_behaves_like "doesn't allow start signal"
      it_behaves_like "doesn't allow pre_execute signal"
    end

    context "post_execute" do
      let(:state) { "post_execute" }

      it_behaves_like "allows finish signal"
      it_behaves_like "allows abort_job signal"
      it_behaves_like "allows cancel signal"
      it_behaves_like "allows error signal"

      it_behaves_like "doesn't allow start signal"
      it_behaves_like "doesn't allow pre_execute signal"
      it_behaves_like "doesn't allow execute signal"
      it_behaves_like "doesn't allow poll_runner signal"
      it_behaves_like "doesn't allow post_execute signal"
    end
  end

  context ".execute" do
    let(:state) { "pre_execute" }
    let(:response_async) { Ansible::Runner::ResponseAsync.new(:base_dir => "/path/to/results") }

    it "ansible-runner succeeds" do
      response_async = Ansible::Runner::ResponseAsync.new(:base_dir => "/path/to/results")
      runner_options = [
        {"ENV" => "VAR"},
        {"arg1" => "val1"},
        "role_name",
        {
          :roles_path      => "path/role",
          :role_skip_facts => true
        }
      ]

      expect(Ansible::Runner).to receive(:run_role_async).with(*runner_options).and_return(response_async)
      expect(job).to receive(:queue_signal).with(:poll_runner)

      job.signal(:execute)

      expect(job.context[:ansible_runner_response]).to eq(response_async.dump)
    end

    it "ansible-runner fails" do
      expect(Ansible::Runner).to receive(:run_role_async).and_return(nil)
      expect(job).to receive(:queue_signal).with(:abort, "Failed to run ansible role", "error")

      job.signal(:execute)
    end
  end

  context "#current_job_timeout" do
    it "sets the job current timeout" do
      expect(job.current_job_timeout).to eq(1.hour)
    end
  end

  context ".poll_runner" do
    let(:state)          { "running" }
    let(:response_async) { Ansible::Runner::ResponseAsync.new(:base_dir => "/path/to/results") }

    before do
      allow(Ansible::Runner::ResponseAsync).to receive(:new).and_return(response_async)

      job.context[:ansible_runner_response] = response_async.dump
      job.started_on = Time.now.utc
      job.save!
    end

    it "ansible-runner completed" do
      expect(response_async).to receive(:running?).and_return(false)

      response = Ansible::Runner::Response.new(response_async.dump.merge(:return_code => 0))
      expect(response_async).to receive(:response).and_return(response)
      expect(job).to receive(:queue_signal).with(:post_execute)

      job.signal(:poll_runner)
    end

    it "ansible-runner still running" do
      now = Time.now.utc
      allow(Time).to receive(:now).and_return(now)
      expect(response_async).to receive(:running?).and_return(true)
      expect(job).to receive(:queue_signal).with(:poll_runner, :deliver_on => now + 1.second)

      job.signal(:poll_runner)
    end

    it "fails if the role has been running too long" do
      time = job.started_on + job.options[:timeout] + 5.minutes

      Timecop.travel(time) do
        expect(response_async).to receive(:running?).and_return(true)
        expect(response_async).to receive(:stop)
        expect(job).to receive(:queue_signal).with(:abort, "ansible role has been running longer than timeout", "error")

        job.signal(:poll_runner)
      end
    end

    context ".deliver_on" do
      let(:options) { [{"ENV" => "VAR"}, {"arg1" => "val1"}, {:roles_path => "/path/to/role"}, :poll_interval => 5.minutes] }

      it "uses the option to queue poll_runner" do
        now = Time.now.utc
        allow(Time).to receive(:now).and_return(now)
        expect(response_async).to receive(:running?).and_return(true)
        expect(job).to receive(:queue_signal).with(:poll_runner, :deliver_on => now + 5.minutes)

        job.signal(:poll_runner)
      end
    end
  end
end
