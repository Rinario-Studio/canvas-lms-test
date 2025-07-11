# frozen_string_literal: true

#
# Copyright (C) 2011 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

class ConversationParticipant < ActiveRecord::Base
  include Workflow
  include TextHelper
  include SimpleTags
  include ModelCache
  include ConversationHelper

  belongs_to :conversation
  belongs_to :user
  # deprecated
  has_many :conversation_message_participants

  after_destroy :destroy_conversation_message_participants

  scope :visible, -> { where.not(last_message_at: nil) }
  scope :default, -> { where(workflow_state: ["read", "unread"]) }
  scope :unread, -> { where(workflow_state: "unread") }
  scope :archived, -> { where(workflow_state: "archived") }
  scope :starred, -> { where(label: "starred") }
  scope :sent, -> { where.not(visible_last_authored_at: nil).order("visible_last_authored_at DESC, conversation_id DESC") }
  scope :for_masquerading_user, lambda { |masquerading_user, user_being_viewed|
    # site admins can see everything
    next all if masquerading_user.account_users.active.map(&:account_id).include?(Account.site_admin.id)

    # we need to ensure that the user can access *all* of each conversation's
    # accounts (and that each conversation has at least one account). so given
    # a user who can access accounts 1-5, we construct a sql string like so:
    #  '[1][2][3][4][5]' like '%[' || REPLACE(root_account_ids, ',', ']%[') || ']%'
    #
    # which when applied to a given row would be something like:
    #  '[1][2][3][4][5]' like '%[2]%[4]%'
    #
    # note that we are reliant on root_account_ids always being in order. if
    # they aren't, this scope will be totally broken (it could be written
    # another slower way)
    #
    # we're also counting on conversations being in the join

    own_root_account_ids = Shard.birth.activate do
      # check the target user's accounts - the masquerader may still have rights even if they're not directly associated
      accts = (
          masquerading_user.associated_root_accounts.shard(masquerading_user.in_region_associated_shards).to_a +
          user_being_viewed.associated_root_accounts.shard(user_being_viewed.in_region_associated_shards).to_a
        ).uniq.select { |a| a.grants_right?(masquerading_user, :become_user) }
      # we really shouldn't need the global id here, but we've got a lot of participants with
      # global id's in their root_account_ids for some reason
      accts.map(&:id) + accts.map(&:global_id)
    end
    own_root_account_ids.sort!.uniq!
    id_string = "[" + own_root_account_ids.join("][") + "]"
    root_account_id_matcher = "'%[' || REPLACE(conversation_participants.root_account_ids, ',', ']%[') || ']%'"
    where("conversation_participants.root_account_ids <> '' AND " + like_condition("?", root_account_id_matcher, downcase: false), id_string)
  }

  # Produces a subscope for conversations in which the given users are
  # participants (either all or any, depending on options[:mode]).
  #
  # The execution of subqueries and general complexity is due to the fact that
  # the existence of a CP for any given user can only be guaranteed on the
  # user's shard and the conversation's shard. To get a condition that can be
  # applied on a single shard (for the scope being constructed) we basically
  # have to execute this condition immediately and then just limit on the
  # resulting ids into the scope we're building.
  #
  # Performance assumptions:
  #
  # * number of unique shards among given user tags is small (there will be one
  #   query per such shard)
  # * the number of unique shards on which those users have conversations is
  #   relatively small (there will be one query per such shard)
  # * number of found conversations is relatively small (each will be
  #   instantiated to get id)
  #
  tagged_scope_handler(/\Auser_(\d+)\z/) do |tags, options|
    if (s = all.shard_value) && s.is_a?(Shard)
      scope_shard = s
    end
    scope_shard ||= Shard.current
    exterior_user_ids = tags.map { |t| t.delete_prefix("user_").to_i }

    # which users have conversations on which shards?
    users_by_conversation_shard =
      ConversationParticipant.users_by_conversation_shard(exterior_user_ids)

    # invert the map (to get shards-for-each-user rather than
    # users-for-each-shard), then combine the keys (shards) according to mode.
    # i.e. if we want conversations with all given users participating,
    # intersect the set of shards; otherwise union them.
    conversation_shards_by_user = {}
    exterior_user_ids.each do |user_id|
      conversation_shards_by_user[user_id] ||= Set.new
    end
    users_by_conversation_shard.each do |shard, user_ids|
      user_ids.each do |user_id|
        user_id = Shard.relative_id_for(user_id, shard, Shard.current)
        conversation_shards_by_user[user_id] << shard
      end
    end
    combinator = (options[:mode] == :or) ? :| : :&
    conversation_shards =
      conversation_shards_by_user.values.inject(combinator).to_a

    # which conversations from those shards include any/all of the given users
    # as participants?
    conditions = Shard.with_each_shard(conversation_shards) do
      user_ids = users_by_conversation_shard[Shard.current]

      shard_conditions = if options[:mode] == :or || user_ids.size == 1
                           [<<~SQL.squish, user_ids]
                             EXISTS (
                               SELECT *
                               FROM #{ConversationParticipant.quoted_table_name} cp
                               WHERE cp.conversation_id = conversation_participants.conversation_id
                               AND user_id IN (?)
                             )
                           SQL
                         else
                           [<<~SQL.squish, user_ids, user_ids.size]
                             (
                               SELECT COUNT(*)
                               FROM #{ConversationParticipant.quoted_table_name} cp
                               WHERE cp.conversation_id = conversation_participants.conversation_id
                               AND user_id IN (?)
                             ) = ?
                           SQL
                         end

      # return arrays because with each shard is gonna try and Array() it
      # anyways, and 1.8.7 would split up the multiline strings.
      if Shard.current == scope_shard
        [sanitize_sql(shard_conditions)]
      else
        ConversationParticipant.unscoped do
          conversation_ids = ConversationParticipant.where(shard_conditions).pluck(:conversation_id).map do |id|
            Shard.relative_id_for(id, Shard.current, scope_shard)
          end
          if conversation_ids.empty?
            []
          else
            ["conversation_id IN (#{conversation_ids.join(",")})"]
          end
        end
      end
    end

    # tagged will flatten a [single_condition] or [] into the list of
    # conditions it's building up, but if we've got multiple conditions here,
    # we want to make sure they're combined with OR regardless of
    # options[:mode], since they're results per shard that we want to combine;
    # each individual condition already takes options[:mode] into account)
    if conditions.size > 1
      "(#{conditions.join(" OR ")})"
    else
      conditions
    end
  end

  tagged_scope_handler(/\A(course|group|section)_(\d+)\z/) do |tags, _|
    tags.map do |tag|
      # tags in the database use the id relative to the default shard. ids in
      # the filters are assumed relative to the current shard and need to be
      # cast to an id relative to the default shard before use in queries.
      type, id = ActiveRecord::Base.parse_asset_string(tag)
      id = Shard.relative_id_for(id, Shard.current, Shard.birth)
      wildcard("conversation_participants.tags", "#{type.underscore}_#{id}", delimiter: ",")
    end
  end

  cacheable_method :user
  cacheable_method :conversation

  delegate :private?, to: :conversation
  delegate :context_name, to: :conversation
  delegate :context_components, to: :conversation

  before_create :set_root_account_ids
  before_update :update_unread_count_for_update
  before_destroy :update_unread_count_for_destroy

  validates :conversation_id, :user_id, :workflow_state, presence: true
  validates :label, inclusion: { in: ["starred"], allow_nil: true }

  def as_json(options = {})
    latest = last_message
    latest_authored = last_authored_message
    subject = conversation.subject
    options[:include_context_info] ||= private?
    {
      id: conversation_id,
      subject:,
      workflow_state:,
      last_message: latest ? CanvasTextHelper.truncate_text(latest.body, max_length: 100) : nil,
      last_message_at:,
      last_authored_message: latest_authored ? CanvasTextHelper.truncate_text(latest_authored.body, max_length: 100) : nil,
      last_authored_message_at: latest_authored ? latest_authored.created_at : visible_last_authored_at,
      message_count:,
      subscribed: subscribed?,
      private: private?,
      starred:,
      properties: properties(latest || latest_authored)
    }.with_indifferent_access
  end

  def all_messages
    conversation.shard.activate do
      ConversationMessage.shard(conversation.shard)
                         .select("conversation_messages.*, conversation_message_participants.tags")
                         .joins(:conversation_message_participants)
                         .where("conversation_id=? AND user_id=?", conversation_id, user_id)
                         .order("created_at DESC, id DESC")
    end
  end

  def messages
    all_messages.where("(workflow_state <> ? OR workflow_state IS NULL)", "deleted")
  end

  def participants(options = {})
    participants = shard.activate do
      key = [conversation, "participants"].cache_key
      participants = Rails.cache.fetch(key) { conversation.participants }
      if options[:include_indirect_participants]
        indirect_key = [conversation, user, "indirect_participants"].cache_key
        participants += Rails.cache.fetch(indirect_key) do
          user_ids = messages.map(&:all_forwarded_messages).flatten.map(&:author_id)
          user_ids -= participants.map(&:id)
          AddressBook.available(user_ids)
        end
      end
      participants
    end

    if options[:include_participant_contexts]
      user.address_book.preload_users(participants)
    end

    participants
  end

  def clear_participants_cache
    shard.activate do
      key = [conversation, "participants"].cache_key
      Rails.cache.delete(key)
      indirect_key = [conversation, user, "indirect_participants"].cache_key
      Rails.cache.delete(indirect_key)
    end
  end

  def properties(latest = last_message)
    properties = []
    properties << :last_author if last_author?(latest)
    properties << :attachments if has_attachments?
    properties << :media_objects if has_media_objects?
    properties
  end

  def last_author?(latest = last_message)
    latest && latest.author_id == user_id
  end

  def add_participants(users, options = {})
    conversation.add_participants(user, users, options)
  end

  def add_message(body_or_obj, options = {})
    conversation.add_message(user, body_or_obj, options.merge(generated: false))
  end

  def process_new_message(message_args, recipients, included_message_ids, tags)
    if recipients && !private?
      add_participants recipients, no_messages: true
    end
    reload

    if included_message_ids
      ConversationMessage.where(id: included_message_ids).each do |msg|
        conversation.add_message_to_participants(msg, new_message: false, only_users: recipients, reset_unread_counts: false)
      end
    end

    message = Conversation.build_message(*message_args)
    add_message(message, tags:, update_for_sender: false, only_users: recipients)

    message
  end

  # if this is false, should queue a job to add the message, don't wait
  def should_process_immediately?
    conversation.conversation_participants.count < Setting.get("max_immediate_conversation_participants", 100).to_i
  end

  # Public: soft deletes the message participants for this conversation
  # participant for the specified messages. May pass :all to soft delete all
  # message participants.
  #
  # to_delete - the list of messages to the delete
  #
  # Returns nothing.
  def remove_messages(*to_delete)
    remove_or_delete_messages(:remove, *to_delete)
  end

  # Public: hard deletes the message participants for this conversation
  # participant for the specified messages. May pass :all to hard delete all
  # message participants.
  #
  # to_delete - the list of messages to the delete
  #
  # Returns nothing.
  def delete_messages(*to_delete)
    remove_or_delete_messages(:delete, *to_delete)
  end

  # Internal: soft or hard delete message participants, based on the indicated
  # operation. Used by remove_messages and delete_messages methods.
  #
  # operation - The operation to perform.
  #             :remove - Only set the workflow state on the message
  #             participants.
  #             :delete to delete the message participants from the database.
  # to_delete - The list of conversation_messages to operate on. This function
  #             only affects the conversation_message_participants for this
  #             participant.
  #
  # Returns nothing.
  def remove_or_delete_messages(operation, *to_delete)
    conversation.shard.activate do
      scope = ConversationMessageParticipant.joins(:conversation_message)
                                            .where(conversation_messages: { conversation_id: },
                                                   user_id:)
      if to_delete == [:all]
        if operation == :delete
          scope.delete_all
        else
          scope.update_all(workflow_state: "deleted", deleted_at: Time.zone.now)
        end
      else
        if operation == :delete
          scope.where(conversation_message_id: to_delete).delete_all
        else
          scope.where(conversation_message_id: to_delete).update_all(workflow_state: "deleted", deleted_at: Time.zone.now)
        end
        # if the only messages left are generated ones, e.g. "added
        # bob to the conversation", delete those too
        return remove_or_delete_messages(operation, :all) unless messages.where(generated: false).exists?
      end
    end
    unless @destroyed
      update_cached_data
      save
    end
    # update the stream item data but leave the instances alone
    StreamItem.delay_if_production(priority: 25).generate_or_update(conversation)
  end

  def update(hash)
    # subscribed= can update the workflow_state, but an explicit
    # workflow_state should trump that. so we do this first
    subscribed = (hash.key?(:subscribed) ? hash.delete(:subscribed) : hash.delete("subscribed"))
    self.subscribed = subscribed unless subscribed.nil?
    super
  end

  def recent_messages
    messages.limit(10)
  end

  def subscribed=(value)
    super unless private?
    if subscribed_changed?
      if subscribed?
        update_cached_data(recalculate_count: false, set_last_message_at: false, regenerate_tags: false)
        self.workflow_state = "unread" if last_message_at_changed? && last_message_at > last_message_at_was
      elsif unread?
        self.workflow_state = "read"
      end
    end
    subscribed?
  end

  def starred
    label == "starred"
  end
  alias_method :starred?, :starred

  def starred=(val)
    # if starred were an actual boolean column, this is the method that would
    # be used to convert strings to appropriate boolean values (e.g. 'true' =>
    # true and 'false' => false)
    self.label = Canvas::Plugin.value_to_boolean(val) ? "starred" : nil
  end

  def one_on_one?
    conversation.conversation_participants.size == 2 && private?
  end

  def other_participants(participants = conversation.participants)
    participants.reject { |u| u.id == user_id }
  end

  def other_participant
    other_participants.first
  end

  workflow do
    state :unread
    state :read
    state :archived
  end

  def update_cached_data(options = {})
    options = { recalculate_count: true, set_last_message_at: true, regenerate_tags: true }.update(options)
    if (latest = last_message)
      self.tags = message_tags if options[:regenerate_tags] && private?
      self.message_count = messages.human.size if options[:recalculate_count]
      self.last_message_at = if last_message_at.nil?
                               options[:set_last_message_at] ? latest.created_at : nil
                             elsif subscribed?
                               latest.created_at
                             else
                               # not subscribed, so set last_message_at to itself (or if that message
                               # was just removed to the closest one before it, or if none, the
                               # closest one after it)
                               times = messages.map(&:created_at)
                               older = times.reject! { |t| t <= last_message_at } || []
                               older.first || times.last
                             end
      self.has_attachments = messages.with_attachments.exists?
      self.has_media_objects = messages.with_media_comments.exists?
      self.visible_last_authored_at = if latest.author_id == user_id
                                        latest.created_at
                                      else
                                        last_authored_message&.created_at
                                      end
    else
      self.tags = nil
      self.workflow_state = "read" if unread?
      self.message_count = 0
      self.last_message_at = nil
      self.has_attachments = false
      self.has_media_objects = false
      self.starred = false
      self.visible_last_authored_at = nil
    end
    # NOTE: last_authored_at doesn't know/care about messages you may
    # have deleted... this is because it is only used by other participants
    # when displaying the most active participants in the conversation.
    # visible_last_authored_at, otoh, takes into account ones you've deleted
    # (see above)
    if options[:recalculate_last_authored_at]
      my_latest = conversation.conversation_messages.human.by_user(user_id).first
      self.last_authored_at = my_latest&.created_at
    end
  end

  def update_cached_data!(*)
    update_cached_data(*)
    save!
  end

  def local_context_tags
    context_tags
  end

  def context_tags
    self["tags"] ? tags.grep(/\A(course|group)_\d+\z/) : infer_tags
  end

  def infer_tags
    conversation.infer_new_tags_for(self, []).first
  end

  def move_to_user(new_user)
    conversation.shard.activate do
      self.class.unscoped do
        old_shard = user.shard
        conversation.conversation_messages.where(author_id: user_id).update_all(author_id: new_user.id)
        if (existing = conversation.conversation_participants.where(user_id: new_user).first)
          existing.update_attribute(:workflow_state, workflow_state) if unread? || existing.archived?
          existing.clear_participants_cache
          destroy
        else
          ConversationMessageParticipant.joins(:conversation_message)
                                        .where(conversation_messages: { conversation_id: }, user_id:)
                                        .update_all(user_id: new_user.id)
          update_attribute :user, new_user
          clear_participants_cache
          existing = self
        end
        # replicate ConversationParticipant record to the new user's shard
        if old_shard != new_user.shard && new_user.shard != conversation.shard && !new_user.all_conversations.where(conversation_id: conversation).exists?
          new_cp = existing.clone
          new_cp.shard = new_user.shard
          new_cp.save!
        end
      end
    end
    self.class.unscoped do
      conversation.regenerate_private_hash! if private?
    end
  end

  attr_writer :last_message

  def last_message
    @last_message ||= messages.human.first if last_message_at
  end

  attr_writer :last_authored_message

  def last_authored_message
    @last_authored_message ||= conversation.shard.activate { messages.human.by_user(user_id).first } if visible_last_authored_at
  end

  def self.preload_latest_messages(conversations, author)
    # preload last_message
    ConversationMessage.preload_latest conversations.select(&:last_message_at)
    # preload last_authored_message
    ConversationMessage.preload_latest conversations.select(&:visible_last_authored_at), author
  end

  def self.conversation_ids
    where_predicates = all.where_clause.instance_variable_get(:@predicates)
    raise "conversation_ids needs to be scoped to a user" unless where_predicates.any? do |v|
      if v.is_a?(Arel::Nodes::Binary) && v.left.is_a?(Arel::Attributes::Attribute)
        v.left.name == "user_id"
      else
        v =~ /user_id (?:= |IN \()\d+/
      end
    end

    order = "last_message_at DESC" unless all.order_values.present?
    self.order(order).pluck(:conversation_id)
  end

  def self.users_by_conversation_shard(user_ids)
    { Shard.current => user_ids }
  end

  def update_one(update_params)
    case update_params[:event]

    when "mark_as_read"
      self.workflow_state = "read"
    when "mark_as_unread"
      self.workflow_state = "unread"
    when "archive"
      self.workflow_state = "archived"

    when "star"
      self.starred = true
    when "unstar"
      self.starred = false

    when "destroy"
      remove_messages(:all)

    end
    save!
  end

  def self.do_batch_update(progress, user, conversation_ids, update_params)
    progress_runner = ProgressRunner.new(progress)
    progress_runner.completed_message do |completed_count|
      t("batch_update_message",
        {
          one: "1 conversation processed",
          other: "%{count} conversations processed"
        },
        count: completed_count)
    end

    progress_runner.do_batch_update(conversation_ids) do |conversation_id|
      participant = user.all_conversations.where(conversation_id:).first
      raise t("not_participating", "The user is not participating in this conversation") unless participant

      InstStatsd::Statsd.distributed_increment("inbox.conversation.unarchived.legacy") if participant[:workflow_state] == "archived" && ["mark_as_read", "mark_as_unread"].include?(update_params[:event])
      participant.update_one(update_params)
    end
  end

  def self.batch_update(user, conversation_ids, update_params)
    progress = user.progresses.create! tag: "conversation_batch_update", completion: 0.0
    job = ConversationParticipant.delay(ignore_transaction: true)
                                 .do_batch_update(progress, user, conversation_ids, update_params)

    # this method is never run by :react_inbox, since at the time of this writing
    # the update_conversation_participants mutation only runs #update and not #batch_update
    InstStatsd::Statsd.count("inbox.conversation.archived.legacy", conversation_ids.size) if update_params[:event] == "archive"
    progress.user_id = user.id
    progress.delayed_job_id = job.id
    progress.save!
    progress
  end

  protected

  def message_tags
    messages.map(&:tags).inject([], &:concat).uniq
  end

  private

  def destroy_conversation_message_participants
    @destroyed = true
    delete_messages(:all) if conversation_id
  end

  def update_unread_count(direction = :up, user_id = self.user_id)
    User.where(id: user_id)
        .update_all(["unread_conversations_count = GREATEST(unread_conversations_count + ?, 0), updated_at = ?", (direction == :up) ? 1 : -1, Time.now.utc])
  end

  def update_unread_count_for_update
    if user_id_changed?
      update_unread_count(:up) if unread?
      update_unread_count(:down, user_id_was) if workflow_state_was == "unread"
    elsif workflow_state_changed? && [workflow_state, workflow_state_was].include?("unread")
      update_unread_count((workflow_state == "unread") ? :up : :down)
    end
  end

  def update_unread_count_for_destroy
    update_unread_count(:down) if unread?
  end
end
