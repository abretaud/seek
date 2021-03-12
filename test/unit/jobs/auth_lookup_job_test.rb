require 'test_helper'
require 'minitest/mock'

class AuthLookupJobTest < ActiveSupport::TestCase
  def setup
    @val = Seek::Config.auth_lookup_enabled
    Seek::Config.auth_lookup_enabled = true
    AuthLookupUpdateQueue.destroy_all
  end

  def teardown
    Seek::Config.auth_lookup_enabled = @val
  end

  test 'add items to queue' do
    sop = Factory :sop
    data = Factory :data_file

    # need to clear the queue for items added through callbacks in the creation of the test items
    AuthLookupUpdateQueue.destroy_all

    assert_enqueued_with(job: AuthLookupUpdateJob) do
      assert_difference('AuthLookupUpdateQueue.count', 2) do
        AuthLookupUpdateQueue.enqueue(sop, data, sop)
      end
    end

    assert_equal [data, sop], AuthLookupUpdateQueue.all.collect(&:item).sort_by { |i| i.class.name }
    items = AuthLookupUpdateJob.new.send(:gather_items)
    assert_equal 2, items.length
    assert_includes items, sop
    assert_includes items, data

    AuthLookupUpdateQueue.destroy_all
    assert_enqueued_with(job: AuthLookupUpdateJob) do
      assert_difference('AuthLookupUpdateQueue.count', 1) do
        AuthLookupUpdateQueue.enqueue(nil)
      end
    end
    assert_nil AuthLookupUpdateQueue.first.item
    items = AuthLookupUpdateJob.new.send(:gather_items)
    assert_includes items, nil
  end

  test 'perform' do
    Sop.delete_all
    user = Factory :user
    other_user = Factory :user
    sop = Factory :sop, contributor: user.person, policy: Factory(:editing_public_policy)
    AuthLookupUpdateQueue.destroy_all
    AuthLookupUpdateQueue.enqueue(sop)
    Sop.clear_lookup_table

    assert_difference('AuthLookupUpdateQueue.count', -1) do
      AuthLookupUpdateJob.new.perform
    end

    #+1 to User count to include anonymous user
    assert_equal User.count + 1, Sop::AuthLookup.count

    assert Sop.lookup_table_consistent?(user.id)
    assert Sop.lookup_table_consistent?(other_user.id)
  end

  test 'takes items from queue according to batch size configuration' do
    # Creating SOPs will automatically enqueue them in the AuthLookupUpdateQueue on save
    FactoryGirl.create_list(:sop, 10)

    with_config_value(:auth_lookup_update_batch_size, 3) do
      assert_difference('AuthLookupUpdateQueue.count', -3) do
        AuthLookupUpdateJob.new.perform
      end
    end

    with_config_value(:auth_lookup_update_batch_size, 7) do
      assert_difference('AuthLookupUpdateQueue.count', -7) do
        AuthLookupUpdateJob.new.perform
      end
    end
  end

  test 'exception handling' do
    Sop.delete_all
    user = Factory :user
    other_user = Factory :user
    sop = Factory :sop, contributor: user.person, policy: Factory(:editing_public_policy)
    AuthLookupUpdateQueue.destroy_all
    AuthLookupUpdateQueue.enqueue(sop)
    Sop.clear_lookup_table

    with_config_value(:exception_notification_enabled, true) do
      assert_difference('AuthLookupUpdateQueue.count', -1) do
        job = AuthLookupUpdateJob.new
        begin
          # Stub because exception forwarding doesn't work in tests
          Seek::Errors::ExceptionForwarder.stub(:send_notification, -> (exception, opts = {}, *_) { raise "Exception was: #{exception.inspect}, item id: #{opts[:data][:item].id}" }) do
            job.stub(:perform_job, -> (*_) { raise 'job error!' }) do # Stub to throw an error
              job.perform
            end
          end
        end
      rescue RuntimeError => e
        assert_equal "#<RuntimeError: Exception was: #<RuntimeError: job error!>, item id: #{sop.id}>", e.inspect
      end
    end
  end
end
