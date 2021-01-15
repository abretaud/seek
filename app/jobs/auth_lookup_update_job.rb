class AuthLookupUpdateJob < BatchJob
  include CommonSweepers

  queue_as QueueNames::AUTH_LOOKUP
  queue_with_priority 0

  def timelimit
    1.hour
  end

  def follow_on_job?
    AuthLookupUpdateQueue.any?
  end

  private

  def perform_job(item)
    if item.nil?
      update_assets_for_user nil
    elsif item.authorization_supported?
      update_for_each_user item
    elsif item.is_a?(User)
      update_assets_for_user item
    elsif item.is_a?(Person)
      update_assets_for_user item.user unless item.user.nil?
    else
      Rails.logger.error("Unexpected type encountered: #{item.class.name}")
    end

    # required to make sure that cached fragments that contain details related to authorization are regenerated after the job has run
    expire_auth_related_fragments
  end

  def gather_items
    # including item_type in the order, encourages assets to be processed before users (since they are much quicker), due to the happy coincidence
    # that User falls last alphabetically. Its not that important if a new authorized type is added after User in the future.
    AuthLookupUpdateQueue.dequeue(Seek::Config.auth_lookup_update_batch_size)
  end

  def update_for_each_user(item)
    item.update_lookup_table_for_all_users
  end

  def update_assets_for_user(user)
    User.transaction(requires_new: true) do
      Seek::Util.authorized_types.each do |type|
        type.includes(policy: :permissions).find_each do |item|
          item.update_lookup_table(user)
        end
      end
    end
  end
end
