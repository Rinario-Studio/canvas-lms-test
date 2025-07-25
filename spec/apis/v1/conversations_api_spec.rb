# frozen_string_literal: true

#
# Copyright (C) 2011 - 2013 Instructure, Inc.
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

require_relative "../api_spec_helper"

describe ConversationsController, type: :request do
  before :once do
    @other = user_factory(active_all: true)

    course_with_teacher(active_course: true, active_enrollment: true, user: user_with_pseudonym(active_user: true))
    @course.update_attribute(:name, "the course")
    @course.account.role_overrides.create!(permission: "send_messages_all", role: teacher_role, enabled: false)
    @course.default_section.update(name: "the section")
    @other_section = @course.course_sections.create(name: "the other section")
    @me = @user

    @bob = student_in_course(name: "bob smith", short_name: "bob")
    @billy = student_in_course(name: "billy")
    @jane = student_in_course(name: "jane")
    @joe = student_in_course(name: "joe")
    @tommy = student_in_course(name: "tommy", section: @other_section)
  end

  def student_in_course(options = {})
    section = options.delete(:section)
    u = User.create(options)
    enrollment = @course.enroll_user(u, "StudentEnrollment", section:)
    enrollment.workflow_state = "active"
    enrollment.save
    u
  end

  def observer_in_course(options = {})
    section = options.delete(:section)
    associated_user = options.delete(:associated_user)
    u = User.create(options)
    enrollment = @course.enroll_user(u, "ObserverEnrollment", section:)
    enrollment.associated_user = associated_user
    enrollment.workflow_state = "active"
    enrollment.save
    u
  end

  context "conversations" do
    it "returns the conversation list" do
      @c1 = conversation(@bob, workflow_state: "read")
      @c2 = conversation(@bob, @billy, workflow_state: "unread", subscribed: false)
      @c3 = conversation(@jane, workflow_state: "archived") # won't show up, since it's archived

      json = api_call(:get,
                      "/api/v1/conversations.json",
                      { controller: "conversations", action: "index", format: "json" })
      json.each { |c| c.delete("avatar_url") } # this URL could change, we don't care
      json.each { |c| c.delete("last_authored_message_at") } # This is sometimes not updated. It's a known bug.
      expect(json).to eql [
        {
          "id" => @c2.conversation_id,
          "subject" => nil,
          "workflow_state" => "unread",
          "last_message" => "test",
          "last_message_at" => @c2.last_message_at.to_json[1, 20],
          "last_authored_message" => "test",
          # "last_authored_message_at" => @c2.last_message_at.to_json[1, 20],
          "message_count" => 1,
          "subscribed" => false,
          "private" => false,
          "starred" => false,
          "properties" => ["last_author"],
          "visible" => true,
          "audience" => [@billy.id, @bob.id],
          "audience_contexts" => {
            "groups" => {},
            "courses" => { @course.id.to_s => [] }
          },
          "participants" => [
            { "id" => @me.id, "name" => @me.short_name, "pronouns" => nil, "full_name" => @me.name },
            { "id" => @billy.id, "name" => @billy.short_name, "pronouns" => nil, "full_name" => @billy.name },
            { "id" => @bob.id, "name" => @bob.short_name, "pronouns" => nil, "full_name" => @bob.name }
          ],
          "context_name" => @c2.context_name,
          "context_code" => @c2.conversation.context_code,
        },
        {
          "id" => @c1.conversation_id,
          "subject" => nil,
          "workflow_state" => "read",
          "last_message" => "test",
          "last_message_at" => @c1.last_message_at.to_json[1, 20],
          "last_authored_message" => "test",
          # "last_authored_message_at" => @c1.last_message_at.to_json[1, 20],
          "message_count" => 1,
          "subscribed" => true,
          "private" => true,
          "starred" => false,
          "properties" => ["last_author"],
          "visible" => true,
          "audience" => [@bob.id],
          "audience_contexts" => {
            "groups" => {},
            "courses" => { @course.id.to_s => ["StudentEnrollment"] }
          },
          "participants" => [
            { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name },
            { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name }
          ],
          "context_name" => @c1.context_name,
          "context_code" => @c1.conversation.context_code,
        }
      ]
    end

    it "properlt responds to include[]=participant_avatars" do
      conversation(@bob, workflow_state: "read")

      json = api_call(:get,
                      "/api/v1/conversations.json",
                      { controller: "conversations",
                        action: "index",
                        format: "json",
                        include: ["participant_avatars"] })
      json.each do |conversation|
        conversation["participants"].each do |user|
          expect(user).to have_key "avatar_url"
        end
      end
    end

    it "ignores include[]=participant_avatars if there are too many participants" do
      conversation(@bob, workflow_state: "read")

      stub_const("Api::V1::Conversation::AVATAR_INCLUDE_LIMIT", 1)

      json = api_call(:get,
                      "/api/v1/conversations.json",
                      { controller: "conversations",
                        action: "index",
                        format: "json",
                        include: ["participant_avatars"] })
      json.each do |conversation|
        conversation["participants"].each do |user|
          expect(user).to_not have_key "avatar_url"
        end
      end
    end

    it "stringifies audience ids if requested" do
      @c1 = conversation(@bob, workflow_state: "read")
      @c2 = conversation(@bob, @billy, workflow_state: "unread", subscribed: false)

      json = api_call(:get,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "index", format: "json" },
                      {},
                      { "Accept" => "application/json+canvas-string-ids" })
      audiences = json.pluck("audience")
      expect(audiences).to eq [
        [@billy.id.to_s, @bob.id.to_s],
        [@bob.id.to_s],
      ]
    end

    it "paginates and return proper pagination headers" do
      students = create_users_in_course(@course, 7, return_type: :record)
      students.each { |s| conversation(s) }
      expect(@user.conversations.size).to be 7
      json = api_call(:get,
                      "/api/v1/conversations.json?scope=default&per_page=3",
                      { controller: "conversations", action: "index", format: "json", scope: "default", per_page: "3" })

      expect(json.size).to be 3
      links = response.headers["Link"].split(",")
      expect(links.all? { |l| l.include?("api/v1/conversations") }).to be_truthy
      expect(links.all? { |l| l.scan("scope=default").size == 1 }).to be_truthy
      expect(links.find { |l| l.include?('rel="next"') }).to match(/page=2&per_page=3>/)
      expect(links.find { |l| l.include?('rel="first"') }).to match(/page=1&per_page=3>/)
      expect(links.find { |l| l.include?('rel="last"') }).to match(/page=3&per_page=3>/)

      # get the last page
      json = api_call(:get,
                      "/api/v1/conversations.json?scope=default&page=3&per_page=3",
                      { controller: "conversations", action: "index", format: "json", scope: "default", page: "3", per_page: "3" })
      expect(json.size).to be 1
      links = response.headers["Link"].split(",")
      expect(links.all? { |l| l.include?("api/v1/conversations") }).to be_truthy
      expect(links.all? { |l| l.scan("scope=default").size == 1 }).to be_truthy
      expect(links.find { |l| l.include?('rel="prev"') }).to match(/page=2&per_page=3>/)
      expect(links.find { |l| l.include?('rel="first"') }).to match(/page=1&per_page=3>/)
      expect(links.find { |l| l.include?('rel="last"') }).to match(/page=3&per_page=3>/)
    end

    it "filters conversations by scope" do
      @c1 = conversation(@bob, workflow_state: "read")
      @c2 = conversation(@bob, @billy, workflow_state: "unread", subscribed: false)
      @c3 = conversation(@jane, workflow_state: "read")

      json = api_call(:get,
                      "/api/v1/conversations.json?scope=unread",
                      { controller: "conversations", action: "index", format: "json", scope: "unread" })
      json.each { |c| c.delete("avatar_url") }
      json.each { |c| c.delete("last_authored_message_at") } # This is sometimes not updated. It's a known bug.
      expect(json).to eql [
        {
          "id" => @c2.conversation_id,
          "subject" => nil,
          "workflow_state" => "unread",
          "last_message" => "test",
          "last_message_at" => @c2.last_message_at.to_json[1, 20],
          "last_authored_message" => "test",
          # "last_authored_message_at" => @c2.last_message_at.to_json[1, 20],
          "message_count" => 1,
          "subscribed" => false,
          "private" => false,
          "starred" => false,
          "properties" => ["last_author"],
          "visible" => true,
          "audience" => [@billy.id, @bob.id],
          "audience_contexts" => {
            "groups" => {},
            "courses" => { @course.id.to_s => [] }
          },
          "participants" => [
            { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name },
            { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name },
            { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name }
          ],
          "context_name" => @c2.context_name,
          "context_code" => @c2.conversation.context_code,
        }
      ]
    end

    describe "context_name" do
      before :once do
        @c1 = conversation(@bob, workflow_state: "read") # implicit tag from shared context
        @c2 = conversation(@bob, @billy, workflow_state: "unread", subscribed: false) # manually specified context which would not be implied
        course_with_student(course_name: "the other course")
        conversation = @c2.conversation
        conversation.context = @course
        conversation.save!
        @c2.save!
        @c3 = conversation(@student) # no context
        @user = @me
      end

      describe "index" do
        it "prefers the context but fall back to the first context tag" do
          json = api_call(:get,
                          "/api/v1/conversations.json",
                          { controller: "conversations", action: "index", format: "json" })
          expect(json.pluck("context_name")).to eql([nil, "the other course", "the course"])
        end
      end

      describe "show" do
        it "prefers the context but fall back to the first context tag" do
          json = api_call(:get,
                          "/api/v1/conversations/#{@c1.conversation.id}",
                          { controller: "conversations", action: "show", id: @c1.conversation.id.to_s, format: "json" })
          expect(json["context_name"]).to eql("the course")
          json = api_call(:get,
                          "/api/v1/conversations/#{@c2.conversation.id}",
                          { controller: "conversations", action: "show", id: @c2.conversation.id.to_s, format: "json" })
          expect(json["context_name"]).to eql("the other course")
          json = api_call(:get,
                          "/api/v1/conversations/#{@c3.conversation.id}",
                          { controller: "conversations", action: "show", id: @c3.conversation.id.to_s, format: "json" })
          expect(json["context_name"]).to be_nil
        end
      end
    end

    context "filtering by tags" do
      specs_require_sharding

      before :once do
        @conversations = []
      end

      def verify_filter(filter)
        @user = @me
        json = api_call(:get,
                        "/api/v1/conversations.json?filter=#{filter}",
                        { controller: "conversations", action: "index", format: "json", filter: })
        expect(json.size).to eq @conversations.size
        expect(json.pluck("id").sort).to eq @conversations.map(&:conversation_id).sort
      end

      context "admin is disabled" do
        def setup_data
          # setting up a teacher with removed admin.
          # the teacher and student share two coures.
          # the conversation is from one course, but
          # returns from either filter, if the admin was active.

          teacher = User.create!(name: "teacher")
          student = User.create!(name: "student")

          # creating courses with methods, ensures tags are setup properly
          course_with_teacher(name: "first course", active_course: true, active_enrollment: true, user: teacher)
          @course_1 = @course
          @course_2 = course_with_student(name: "second course", active_course: true, active_enrollment: true, user: student)
          @course_2 = @course
          @course_1.enroll_student(student, enrollment_state: :active)
          @course_2.enroll_teacher(teacher, enrollment_state: :active)

          account_admin_user(user: teacher)
          # deactivate admin status
          teacher.account_users.destroy_all

          conversation = Conversation.initiate([student, teacher], false, context_type: "Course", context_id: @course_1.id)
          conversation.add_message(teacher, "hello")
          conversation.add_message(student, "hello back")
          @user = teacher
        end

        it "sets context_code to course" do
          setup_data
          json_course_1 = api_call(:get,
                                   "/api/v1/conversations.json?filter=#{@course_1.asset_string}",
                                   { controller: "conversations", action: "index", format: "json", filter: @course_1.asset_string, scope: "default" })

          expect(json_course_1[0]["context_code"]).to_not eq(Account.default.asset_string)
          expect(json_course_1[0]["context_code"]).to eq(@course_1.asset_string)
        end
      end

      context "tag context on default shard" do
        before :once do
          Shard.default.activate do
            account = Account.create!
            course_with_teacher(account:, active_course: true, active_enrollment: true, user: @me)
            @course.update_attribute(:name, "another course")
            @alex = student_in_course(name: "alex")
            @buster = student_in_course(name: "buster")
          end

          @conversations << conversation(@alex)
          @conversations << @shard1.activate { conversation(@buster) }
        end

        it "recognizes filter on the default shard" do
          verify_filter(@course.asset_string)
        end

        it "recognizes filter on an unrelated shard" do
          @shard2.activate { verify_filter(@course.asset_string) }
        end

        it "recognizes explicitly global filter on the default shard" do
          verify_filter(@course.global_asset_string)
        end
      end

      context "tag context on non-default shard" do
        before :once do
          @shard1.activate do
            account = Account.create!
            course_with_teacher(account:, active_course: true, active_enrollment: true, user: @me)
            @course.update_attribute(:name, "the course 2")
            @alex = student_in_course(name: "alex")
            @buster = student_in_course(name: "buster")
          end

          @conversations << @shard1.activate { conversation(@alex) }
          @conversations << conversation(@buster)
        end

        it "recognizes filter on the default shard" do
          verify_filter(@course.asset_string)
        end

        it "recognizes filter on the context's shard" do
          @shard1.activate { verify_filter(@course.asset_string) }
        end

        it "recognizes filter on an unrelated shard" do
          @shard2.activate { verify_filter(@course.asset_string) }
        end

        it "recognizes explicitly global filter on the context's shard" do
          @shard1.activate { verify_filter(@course.global_asset_string) }
        end
      end

      context "tag user on default shard" do
        before :once do
          Shard.default.activate do
            account = Account.create!
            course_with_teacher(account:, active_course: true, active_enrollment: true, user: @me)
            @course.update_attribute(:name, "another course")
            @alex = student_in_course(name: "alex")
          end

          @conversations << conversation(@alex)
        end

        it "recognizes filter on the default shard" do
          verify_filter(@alex.asset_string)
        end

        it "recognizes filter on an unrelated shard" do
          @shard2.activate { verify_filter(@alex.asset_string) }
        end
      end

      context "tag user on non-default shard" do
        before :once do
          @shard1.activate do
            account = Account.create!
            course_with_teacher(account:, active_course: true, active_enrollment: true)
            @course.update_attribute(:name, "the course 2")
            @alex = student_in_course(name: "alex")
            @me = @teacher
          end

          @conversations << @shard1.activate { conversation(@alex) }
        end

        it "recognizes filter on the default shard" do
          verify_filter(@alex.asset_string)
        end

        it "recognizes filter on the user's shard" do
          @shard1.activate { verify_filter(@alex.asset_string) }
        end

        it "recognizes filter on an unrelated shard" do
          @shard2.activate { verify_filter(@alex.asset_string) }
        end
      end
    end

    context "sent scope" do
      it "sorts by last authored date" do
        expected_times = 5.times.to_a.reverse.map { |h| Time.zone.parse((Time.now.utc - h.hours).to_s) }
        Timecop.travel(expected_times[0]) do
          @c1 = conversation(@bob)
        end
        Timecop.travel(expected_times[1]) do
          @c2 = conversation(@bob, @billy)
        end
        Timecop.travel(expected_times[2]) do
          @c3 = conversation(@jane)
        end

        Timecop.travel(expected_times[3]) do
          @m1 = @c1.conversation.add_message(@bob, "ohai")
        end
        Timecop.travel(expected_times[4]) do
          @m2 = @c2.conversation.add_message(@bob, "ohai")
        end

        json = api_call(:get,
                        "/api/v1/conversations.json?scope=sent",
                        { controller: "conversations", action: "index", format: "json", scope: "sent" })
        expect(json.size).to be 3
        expect(json[0]["id"]).to eql @c3.conversation_id
        expect(json[0]["last_message_at"]).to eql expected_times[2].to_json[1, 20]
        expect(json[0]["last_message"]).to eql "test"

        # This is sometimes not updated. It's a known bug.
        # json[0]['last_authored_message_at'].should eql expected_times[2].to_json[1, 20]

        expect(json[0]["last_authored_message"]).to eql "test"

        expect(json[1]["id"]).to eql @c2.conversation_id
        expect(json[1]["last_message_at"]).to eql expected_times[4].to_json[1, 20]
        expect(json[1]["last_message"]).to eql "ohai"

        # This is sometimes not updated. It's a known bug.
        # json[1]['last_authored_message_at'].should eql expected_times[1].to_json[1, 20]

        expect(json[1]["last_authored_message"]).to eql "test"

        expect(json[2]["id"]).to eql @c1.conversation_id
        expect(json[2]["last_message_at"]).to eql expected_times[3].to_json[1, 20]
        expect(json[2]["last_message"]).to eql "ohai"

        # This is sometimes not updated. It's a known bug.
        # json[2]['last_authored_message_at'].should eql expected_times[0].to_json[1, 20]

        expect(json[2]["last_authored_message"]).to eql "test"
      end

      it "includes conversations with at least one message by the author, regardless of workflow_state" do
        @c1 = conversation(@bob)
        @c2 = conversation(@bob, @billy)
        @c2.conversation.add_message(@bob, "ohai")
        @c2.remove_messages(@message) # delete my original message
        @c3 = conversation(@jane, workflow_state: "archived")

        json = api_call(:get,
                        "/api/v1/conversations.json?scope=sent",
                        { controller: "conversations", action: "index", format: "json", scope: "sent" })
        expect(json.size).to be 2
        expect(json.pluck("id").sort).to eql [@c1.conversation_id, @c3.conversation_id]
      end
    end

    it "shows the calculated audience_contexts if the tags have not been migrated yet" do
      @c1 = conversation(@bob, @billy)
      Conversation.update_all "tags = NULL"
      ConversationParticipant.update_all "tags = NULL"
      ConversationMessageParticipant.update_all "tags = NULL"

      expect(@c1.reload.tags).to be_empty
      expect(@c1.context_tags).to eql [@course.asset_string]

      json = api_call(:get,
                      "/api/v1/conversations.json",
                      { controller: "conversations", action: "index", format: "json" })
      expect(json.size).to be 1
      expect(json.first["id"]).to eql @c1.conversation_id
      expect(json.first["audience_contexts"]).to eql({ "groups" => {}, "courses" => { @course.id.to_s => [] } })
    end

    it "includes starred conversations in starred scope regardless of if read or archived" do
      @c1 = conversation(@bob, workflow_state: "unread", starred: true)
      @c2 = conversation(@billy, workflow_state: "read", starred: true)
      @c3 = conversation(@jane, workflow_state: "archived", starred: true)

      json = api_call(:get,
                      "/api/v1/conversations.json?scope=starred",
                      { controller: "conversations", action: "index", format: "json", scope: "starred" })
      expect(json.size).to eq 3
      expect(json.pluck("id").sort).to eq [@c1, @c2, @c3].map(&:conversation_id).sort
    end

    it "does not include unstarred conversations in starred scope regardless of if read or archived" do
      @c1 = conversation(@bob, workflow_state: "unread")
      @c2 = conversation(@billy, workflow_state: "read")
      @c3 = conversation(@jane, workflow_state: "archived")

      json = api_call(:get,
                      "/api/v1/conversations.json?scope=starred",
                      { controller: "conversations", action: "index", format: "json", scope: "starred" })
      expect(json).to be_empty
    end

    it "marks all conversations as read" do
      @c1 = conversation(@bob, workflow_state: "unread")
      @c2 = conversation(@bob, @billy, workflow_state: "unread")
      @c3 = conversation(@jane, workflow_state: "archived")

      json = api_call(:post,
                      "/api/v1/conversations/mark_all_as_read.json",
                      { controller: "conversations", action: "mark_all_as_read", format: "json" })
      expect(json).to eql({})

      expect(@me.conversations.unread.size).to be 0
      expect(@me.conversations.default.size).to be 2
      expect(@me.conversations.archived.size).to be 1
    end

    context "create" do
      it "renders error if no body is provided" do
        course_with_teacher(active_course: true, active_enrollment: true, user: @me)
        @bob = student_in_course(name: "bob")

        @message = conversation(@me, sender: @bob).messages.first

        api_call(:post,
                 "/api/v1/conversations/#{@conversation.conversation_id}/add_message",
                 { controller: "conversations",
                   action: "add_message",
                   id: @conversation.conversation_id.to_s,
                   format: "json" })

        assert_status(400)
      end

      it "creates a private conversation" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id], body: "test" })
        json.each do |c|
          c.delete("avatar_url")
          c["participants"].each do |p|
            p.delete("avatar_url")
          end
        end
        json.each { |c| c["messages"].each { |m| m["participating_user_ids"].sort! } }
        json.each { |c| c.delete("last_authored_message_at") } # This is sometimes not updated. It's a known bug.
        conversation = @me.all_conversations.order("conversation_id DESC").first
        expect(json).to eql [
          {
            "id" => conversation.conversation_id,
            "subject" => nil,
            "workflow_state" => "read",
            "last_message" => nil,
            "last_message_at" => nil,
            "last_authored_message" => "test",
            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
            "message_count" => 1,
            "subscribed" => true,
            "private" => true,
            "starred" => false,
            "properties" => ["last_author"],
            "visible" => false,
            "context_code" => conversation.conversation.context_code,
            "audience" => [@bob.id],
            "audience_contexts" => {
              "groups" => {},
              "courses" => { @course.id.to_s => ["StudentEnrollment"] }
            },
            "participants" => [
              { "id" => @me.id, "name" => @me.short_name, "pronouns" => nil, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
              { "id" => @bob.id, "name" => @bob.short_name, "pronouns" => nil, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
            ],
            "messages" => [
              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "test", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @bob.id].sort }
            ]
          }
        ]
      end

      it "adds a context to a private conversation" do
        api_call(:post,
                 "/api/v1/conversations",
                 { controller: "conversations", action: "create", format: "json" },
                 { recipients: [@bob.id], body: "test", context_code: "course_#{@course.id}" })
        expect(@bob.conversations.last.conversation.context).to eql(@course)
      end

      it "does not re-use a private conversation with a different explicit context" do
        course1 = @course
        course2 = course_with_teacher(user: @me, active_all: true).course
        course_with_student(course: course2, user: @bob, active_all: true)

        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id], body: "test", context_code: "course_#{course1.id}" })
        conv1 = Conversation.find(json.first["id"])
        expect(conv1.context).to eql(course1)

        json2 = api_call(:post,
                         "/api/v1/conversations",
                         { controller: "conversations", action: "create", format: "json" },
                         { recipients: [@bob.id], body: "test", context_code: "course_#{course2.id}" })
        conv2 = Conversation.find(json2.first["id"])
        expect(conv2.context).to eql(course2)
      end

      it "re-uses a private conversation with an old contextless private hash if the original context matches" do
        course1 = @course
        course2 = course_with_teacher(user: @me, active_all: true).course
        course_with_student(course: course2, user: @bob, active_all: true)

        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id], body: "test", context_code: "course_#{course1.id}" })
        conv1 = Conversation.find(json.first["id"])
        expect(conv1.context).to eql(course1)

        # revert it to the old format
        old_hash = Conversation.private_hash_for(conv1.conversation_participants.pluck(:user_id))
        ConversationParticipant.where(conversation_id: conv1).update_all(private_hash: old_hash)
        Conversation.where(id: conv1).update_all(private_hash: old_hash)

        json2 = api_call(:post,
                         "/api/v1/conversations",
                         { controller: "conversations", action: "create", format: "json" },
                         { recipients: [@bob.id], body: "test", context_code: "course_#{course1.id}" })
        expect(json2.first["id"]).to eq conv1.id # should reuse the conversation

        json3 = api_call(:post,
                         "/api/v1/conversations",
                         { controller: "conversations", action: "create", format: "json" },
                         { recipients: [@bob.id], body: "test", context_code: "course_#{course2.id}" })
        expect(json3.first["id"]).to_not eq conv1.id # should make a new one
      end

      it "creates a new conversation if force_new parameter is provided" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id], body: "test", subject: "subject_1", force_new: "true" })
        conv1 = Conversation.find(json.first["id"])

        json2 = api_call(:post,
                         "/api/v1/conversations",
                         { controller: "conversations", action: "create", format: "json" },
                         { recipients: [@bob.id], body: "test", subject: "subject_2", force_new: "true" })
        conv2 = Conversation.find(json2.first["id"])
        expect(conv2.id).to_not eq conv1.id # should make a new one
      end

      it "does not break trying to pull cached conversations for re-use" do
        course1 = @course
        course_with_student(course: course1, user: @billy, active_all: true)
        course2 = course_with_teacher(user: @me, active_all: true).course
        course_with_student(course: course2, user: @bob, active_all: true)

        @user = @me
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id, @billy.id], body: "test", context_code: "course_#{course1.id}" })
        conv1 = Conversation.find(json.first["id"])
        expect(conv1.context).to eql(course1)

        # revert one to the old format - leave the other alone
        old_hash = Conversation.private_hash_for(conv1.conversation_participants.pluck(:user_id))
        ConversationParticipant.where(conversation_id: conv1).update_all(private_hash: old_hash)
        Conversation.where(id: conv1).update_all(private_hash: old_hash)

        json2 = api_call(:post,
                         "/api/v1/conversations",
                         { controller: "conversations", action: "create", format: "json" },
                         { recipients: [@bob.id, @billy.id], body: "test", context_code: "course_#{course1.id}" })
        expect(json2.pluck("id")).to include(conv1.id) # should reuse the conversation
      end

      describe "context is an account for admins validation" do
        it "allows root account context if the user is an admin on that account" do
          account_admin_user active_all: true
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id], body: "test", context_code: "account_#{Account.default.id}" })
          conv = Conversation.find(json.first["id"])
          expect(conv.context).to eq Account.default
        end

        it "does not allow account context if the user is not an admin in that account" do
          raw_api_call(:post,
                       "/api/v1/conversations",
                       { controller: "conversations", action: "create", format: "json" },
                       { recipients: [@bob.id], body: "test", context_code: "account_#{Account.default.id}" })
          assert_status(400)
        end

        it "allows an admin to send a message in course context" do
          account_admin_user active_all: true
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id], body: "test", context_code: @course.asset_string })
          conv = Conversation.find(json.first["id"])
          expect(conv.context).to eq @course
        end

        # Otherwise, students can't reply to admins because admins are not in the course
        # context
        it "uses account context if messages are coming from an admin through a course" do
          account_admin_user active_all: true
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id], body: "test", context_code: @course.asset_string })
          expect(json.first["context_code"]).to eq "account_#{Account.default.id}"
        end

        it "still uses course context if messages are NOT coming from an admin through a course" do
          conversation = conversation(@bob, context_type: "Course", context_id: @course.id)
          json = api_call(:get,
                          "/api/v1/conversations/#{conversation.conversation_id}",
                          { controller: "conversations",
                            action: "show",
                            id: conversation.conversation_id.to_s,
                            format: "json", })
          expect(json["context_code"]).to eq @course.asset_string
        end

        it "always has the right tags when sending a bulk message in course context" do
          other_course = Account.default.courses.create!(workflow_state: "available")
          other_course.enroll_teacher(@user).accept!
          other_course.enroll_student(@bob).accept!
          # if they happen to be in another course it shouldn't use those tags - otherwise it will show up in the "sent" for other courses
          @course.account.role_overrides.where(permission: "send_messages_all", role: teacher_role).update_all(enabled: true)

          api_call(:post,
                   "/api/v1/conversations",
                   { controller: "conversations", action: "create", format: "json" },
                   { recipients: [@course.asset_string],
                     body: "test",
                     context_code: @course.asset_string,
                     bulk_message: "1",
                     group_conversation: "1" })

          @user.all_conversations.sent.each do |cp|
            expect(cp.tags).to eq [@course.asset_string]
          end
        end

        it "allows users to send messages to themselves" do
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@user.id], body: "hello, me", context_code: @course.asset_string })
          expect(response).to be_successful
          expect(json[0]["messages"][0]["participating_user_ids"]).to eq([@user.id])
        end

        it "allows site admin to set any account context" do
          site_admin_user(name: "site admin", active_all: true)
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id], body: "test", context_code: "account_#{Account.default.id}" })
          conv = Conversation.find(json.first["id"])
          expect(conv.context).to eq Account.default
        end

        context "sub-accounts" do
          before :once do
            @sub_account = Account.default.sub_accounts.build(name: "subby")
            @sub_account.root_account_id = Account.default.id
            @sub_account.save!
            account_admin_user(account: @sub_account, name: "sub admin", active_all: true)
          end

          it "allows root account context if the user is an admin on a sub-account" do
            course_with_student(account: @sub_account, name: "sub student", active_all: true)
            @user = @admin
            json = api_call(:post,
                            "/api/v1/conversations",
                            { controller: "conversations", action: "create", format: "json" },
                            { recipients: [@student.id], body: "test", context_code: "account_#{Account.default.id}" })
            conv = Conversation.find(json.first["id"])
            expect(conv.context).to eq Account.default
          end

          it "does not allow non-root account context" do
            raw_api_call(:post,
                         "/api/v1/conversations",
                         { controller: "conversations", action: "create", format: "json" },
                         { recipients: [@bob.id], body: "test", context_code: "account_#{@sub_account.id}" })
            assert_status(400)
          end

          context "cross-shard" do
            specs_require_sharding

            it "finds valid context for user on other shard" do
              @shard1.activate do
                new_root = Account.create!(name: "shard2 account")
                sub_account = new_root.sub_accounts.create!(name: "sub dept")
                course_with_student(account: sub_account, name: "sub student", active_all: true)
                # @admin is defined above and is from the default shard.
                account_admin_user(user: @admin, account: sub_account, name: "sub admin", active_all: true)
                json = api_call(:post,
                                "/api/v1/conversations",
                                { controller: "conversations", action: "create", format: "json" },
                                { recipients: [@student.id], body: "test", context_code: "account_#{new_root.id}" })
                conv = Conversation.find(json.first["id"])
                expect(conv.context).to eq new_root
              end
            end
          end
        end
      end

      it "creates a group conversation" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id, @billy.id], body: "test", group_conversation: true })
        json.each do |c|
          c.delete("avatar_url")
          c["participants"].each do |p|
            p.delete("avatar_url")
          end
        end
        json.each { |c| c["messages"].each { |m| m["participating_user_ids"].sort! } }
        json.each { |c| c.delete("last_authored_message_at") } # This is sometimes not updated. It's a known bug.
        conversation = @me.all_conversations.order("conversation_id DESC").first
        expect(json).to eql [
          {
            "id" => conversation.conversation_id,
            "subject" => nil,
            "workflow_state" => "read",
            "last_message" => nil,
            "last_message_at" => nil,
            "last_authored_message" => "test",
            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
            "message_count" => 1,
            "subscribed" => true,
            "private" => false,
            "starred" => false,
            "properties" => ["last_author"],
            "visible" => false,
            "context_code" => conversation.conversation.context_code,
            "audience" => [@billy.id, @bob.id],
            "audience_contexts" => {
              "groups" => {},
              "courses" => { @course.id.to_s => [] }
            },
            "participants" => [
              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
              { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
            ],
            "messages" => [
              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "test", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @billy.id, @bob.id].sort }
            ]
          }
        ]
      end

      context "private conversations" do
        # set up a private conversation in advance
        before(:once) { @conversation = conversation(@bob) }

        it "updates the private conversation if it already exists" do
          conversation = @conversation
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id], body: "test" })
          conversation.reload
          json.each do |c|
            c.delete("avatar_url")
            c["participants"].each do |p|
              p.delete("avatar_url")
            end
          end
          json.each { |c| c["messages"].each { |m| m["participating_user_ids"].sort! } }
          json.each { |c| c.delete("last_authored_message_at") } # This is sometimes not updated. It's a known bug.
          expect(json).to eql [
            {
              "id" => conversation.conversation_id,
              "subject" => nil,
              "workflow_state" => "read",
              "last_message" => "test",
              "last_message_at" => conversation.last_message_at.to_json[1, 20],
              "last_authored_message" => "test",
              # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
              "message_count" => 2, # two messages total now, though we'll only get the latest one in the response
              "subscribed" => true,
              "private" => true,
              "starred" => false,
              "properties" => ["last_author"],
              "visible" => true,
              "context_code" => conversation.conversation.context_code,
              "audience" => [@bob.id],
              "audience_contexts" => {
                "groups" => {},
                "courses" => { @course.id.to_s => ["StudentEnrollment"] }
              },
              "participants" => [
                { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
              ],
              "messages" => [
                { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "test", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @bob.id].sort }
              ]
            }
          ]
        end

        it "create/updates bulk private conversations synchronously" do
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id, @joe.id, @billy.id], body: "test" })
          expect(json.size).to be 3
          expect(json.pluck("id").sort).to eql @me.all_conversations.map(&:conversation_id).sort

          batch = ConversationBatch.first
          expect(batch).not_to be_nil
          expect(batch).to be_sent

          expect(@me.all_conversations.size).to be(3)
          expect(@me.conversations.size).to be(1) # just the initial conversation with bob is visible to @me
          expect(@bob.conversations.size).to be(1)
          expect(@billy.conversations.size).to be(1)
          expect(@joe.conversations.size).to be(1)
        end

        it "sets the context on new synchronous bulk private conversations" do
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id, @joe.id, @billy.id], body: "test", context_code: "course_#{@course.id}" })
          expect(json.size).to be 3

          batch = ConversationBatch.first
          expect(batch).not_to be_nil
          expect(batch).to be_sent

          expect(@me.all_conversations.last.conversation.context).to eq @course
          [@bob, @billy, @joe].each { |u| expect(u.conversations.first.conversation.context).to eql(@course) }
        end

        it "constraints the length of the subject of a conversation batch" do
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id, @joe.id, @billy.id],
                            subject: "Z" * 300,
                            body: "test",
                            context_code: "course_#{@course.id}" },
                          {},
                          { expected_status: 400 })
          expect(json["errors"]["subject"]).to be_present
        end

        it "create/updates bulk private conversations asynchronously" do
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id, @joe.id, @billy.id], body: "test", mode: "async" })
          expect(json).to eql([])

          batch = ConversationBatch.first
          expect(batch).not_to be_nil
          expect(batch).to be_created
          batch.deliver

          expect(@me.all_conversations.size).to be(3)
          expect(@me.conversations.size).to be(1) # just the initial conversation with bob is visible to @me
          expect(@bob.conversations.size).to be(1)
          expect(@billy.conversations.size).to be(1)
          expect(@joe.conversations.size).to be(1)
        end

        it "sets the context on new asynchronous bulk private conversations" do
          json = api_call(:post,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "create", format: "json" },
                          { recipients: [@bob.id, @joe.id, @billy.id], body: "test", mode: "async", context_code: "course_#{@course.id}" })
          expect(json).to eql([])

          batch = ConversationBatch.first
          expect(batch).not_to be_nil
          expect(batch).to be_created
          batch.deliver

          expect(@me.all_conversations.last.conversation.context).to eq @course
          [@bob, @billy, @joe].each { |u| expect(u.conversations.first.conversation.context).to eql(@course) }
        end
      end

      context "with double testing disable_adding_uuid_verifier_in_api ff" do
        before do
          @attachment = @bob.conversation_attachments_folder.attachments.create!(context: @bob, uploaded_data: stub_png_data)
        end

        double_testing_with_disable_adding_uuid_verifier_in_api_ff do
          it "creates a conversation with forwarded messages" do
            forwarded_message = conversation(@me, sender: @bob).messages.first
            forwarded_message.attachment_ids = [@attachment.id]
            forwarded_message.save!

            json = api_call(:post,
                            "/api/v1/conversations",
                            { controller: "conversations", action: "create", format: "json" },
                            { recipients: [@billy.id], body: "test", forwarded_message_ids: [forwarded_message.id] })
            json.each { |c| c.delete("last_authored_message_at") } # This is sometimes not updated. It's a known bug.
            json.each do |c|
              c.delete("avatar_url")
              c["participants"].each do |p|
                p.delete("avatar_url")
              end
            end
            json.each do |c|
              c["messages"].each do |m|
                m["participating_user_ids"].sort!
                m["forwarded_messages"].each { |fm| fm["participating_user_ids"].sort! }
              end
            end
            conversation = @me.all_conversations.order(Conversation.nulls(:first, :last_message_at, :desc)).order("conversation_id DESC").first
            expected = [
              {
                "id" => conversation.conversation_id,
                "subject" => nil,
                "workflow_state" => "read",
                "last_message" => nil,
                "last_message_at" => nil,
                "last_authored_message" => "test",
                # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                "message_count" => 1,
                "subscribed" => true,
                "private" => true,
                "starred" => false,
                "properties" => ["last_author", "attachments"],
                "visible" => false,
                "context_code" => conversation.conversation.context_code,
                "audience" => [@billy.id],
                "audience_contexts" => {
                  "groups" => {},
                  "courses" => { @course.id.to_s => ["StudentEnrollment"] }
                },
                "participants" => [
                  { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                  { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                  { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                ],
                "messages" => [
                  {
                    "id" => conversation.messages.first.id,
                    "created_at" => conversation.messages.first.created_at.to_json[1, 20],
                    "body" => "test",
                    "author_id" => @me.id,
                    "generated" => false,
                    "media_comment" => nil,
                    "attachments" => [],
                    "participating_user_ids" => [@me.id, @billy.id].sort,
                    "forwarded_messages" => [{
                      "id" => forwarded_message.id,
                      "created_at" => forwarded_message.created_at.to_json[1, 20],
                      "body" => "test",
                      "author_id" => @bob.id,
                      "generated" => false,
                      "media_comment" => nil,
                      "forwarded_messages" => [],
                      "attachments" => [{
                        "filename" => @attachment.filename,
                        "url" => "http://www.example.com/files/#{@attachment.id}/download?download_frd=1#{"&verifier=#{@attachment.uuid}" unless disable_adding_uuid_verifier_in_api}",
                        "content-type" => "image/png",
                        "display_name" => "test my file? hai!&.png",
                        "id" => @attachment.id,
                        "folder_id" => @attachment.folder_id,
                        "size" => @attachment.size,
                        "unlock_at" => nil,
                        "locked" => false,
                        "hidden" => false,
                        "lock_at" => nil,
                        "locked_for_user" => false,
                        "hidden_for_user" => false,
                        "created_at" => @attachment.created_at.as_json,
                        "updated_at" => @attachment.updated_at.as_json,
                        "upload_status" => "success",
                        "modified_at" => @attachment.modified_at.as_json,
                        "thumbnail_url" => thumbnail_image_url(@attachment, @attachment.uuid, host: "www.example.com"),
                        "mime_class" => @attachment.mime_class,
                        "media_entry_id" => @attachment.media_entry_id,
                        "category" => "uncategorized"
                      }],
                      "participating_user_ids" => [@me.id, @bob.id].sort
                    }]
                  }
                ]
              }
            ]
            expect(json).to eq expected
          end
        end
      end

      context "cross-shard message forwarding" do
        specs_require_sharding

        it "does not asplode" do
          @shard1.activate do
            course_with_teacher(active_course: true, active_enrollment: true, user: @me)
            @bob = student_in_course(name: "bob")

            @message = conversation(@me, sender: @bob).messages.first
          end
          json = api_call(:post,
                          "/api/v1/conversations/#{@conversation.conversation_id}/add_message",
                          { controller: "conversations", action: "add_message", id: @conversation.conversation_id.to_s, format: "json" },
                          { body: "wut wut", included_messages: [@message.id] })

          expect(json["last_message"]).to eq "wut wut"
          expect(@conversation.reload.message_count).to eq 2 # should not double-update
        end
      end

      it "sets subject" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id], body: "test", subject: "lunch" })
        json.each do |c|
          c.delete("avatar_url")
          c["participants"].each do |p|
            p.delete("avatar_url")
          end
        end
        json.each { |c| c["messages"].each { |m| m["participating_user_ids"].sort! } }
        json.each { |c| c.delete("last_authored_message_at") } # This is sometimes not updated. It's a known bug.
        conversation = @me.all_conversations.order("conversation_id DESC").first
        expect(json).to eql [
          {
            "id" => conversation.conversation_id,
            "subject" => "lunch",
            "workflow_state" => "read",
            "last_message" => nil,
            "last_message_at" => nil,
            "last_authored_message" => "test",
            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
            "message_count" => 1,
            "subscribed" => true,
            "private" => true,
            "starred" => false,
            "properties" => ["last_author"],
            "visible" => false,
            "context_code" => conversation.conversation.context_code,
            "audience" => [@bob.id],
            "audience_contexts" => {
              "groups" => {},
              "courses" => { @course.id.to_s => ["StudentEnrollment"] }
            },
            "participants" => [
              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
            ],
            "messages" => [
              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "test", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @bob.id].sort }
            ]
          }
        ]
      end

      it "sets subject on batch conversations" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id, @joe.id], body: "test", subject: "dinner" })
        expect(json.size).to be 2
        json.each do |c|
          expect(c["subject"]).to eql "dinner"
        end
      end

      it "constrains subject length" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id], body: "test", subject: "a" * 256 },
                        {},
                        { expected_status: 400 })
        expect(json["errors"]).not_to be_nil
        expect(json["errors"]["subject"]).not_to be_nil
      end

      it "respects course's send_messages_all permission" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id, @course.asset_string], body: "test", subject: "hey erryone" },
                        {},
                        { expected_status: 400 })
        expect(json[0]["attribute"]).to eql "recipients"
        expect(json[0]["message"]).to eql "restricted by role"
      end

      it "requires send_messages_all to send to all students" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id, "course_#{@course.id}_students"], body: "test", subject: "hey ho" },
                        {},
                        { expected_status: 400 })
        expect(json[0]["attribute"]).to eql "recipients"
        expect(json[0]["message"]).to eql "restricted by role"
      end

      it "does not require send_messages_all to send to all teachers" do
        api_call(:post,
                 "/api/v1/conversations",
                 { controller: "conversations", action: "create", format: "json" },
                 { recipients: [@bob.id, "course_#{@course.id}_teachers"], body: "test", subject: "halp" },
                 {},
                 { expected_status: 201 })
      end

      it "sends bulk group messages" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id, @joe.id],
                          body: "test",
                          group_conversation: "true",
                          bulk_message: "true" })
        expect(json.size).to be 2
      end

      it "sends bulk group messages with a single recipient" do
        json = api_call(:post,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "create", format: "json" },
                        { recipients: [@bob.id],
                          body: "test",
                          group_conversation: "true",
                          bulk_message: "true" })
        expect(json.size).to be 1
      end

      context "cross-shard creation" do
        specs_require_sharding

        it "creates the conversation on the context's shard" do
          @shard1.activate do
            @other_account = Account.create
            course_with_teacher(active_all: true, account: @other_account, user: @me)
            @other_course = @course
            @other_student = user_with_pseudonym(active_all: true, account: @other_account)
            @other_course.enroll_student(@other_student, enrollment_state: "active")
          end

          @user = @me
          api_call(:post,
                   "/api/v1/conversations",
                   { controller: "conversations", action: "create", format: "json" },
                   { recipients: [@other_student.id], body: "test", context_code: "course_#{@other_course.id}" })
          expect(@other_student.conversations.last.conversation.shard).to eq @shard1
        end

        it "creates a conversation batch on the context's shard" do
          @shard1.activate do
            @other_account = Account.create
            course_factory(active_all: true, account: @other_account)
            @other_course = @course
            @other_students = n_students_in_course(3, course: @other_course)
            teacher_in_course(active_all: true, course: @other_course, user: @me)
          end

          @user = @me
          api_call(:post,
                   "/api/v1/conversations",
                   { controller: "conversations", action: "create", format: "json" },
                   { recipients: @other_students.map(&:id), body: "test", context_code: "course_#{@other_course.id}" })
          batch = @shard1.activate { ConversationBatch.last }
          expect(batch).to be_sent
          @other_students.each { |s| expect(s.conversations.last.conversation.shard).to eq @shard1 }
        end

        it "sends async bulk messages correctly cross-shard" do
          @shard1.activate do
            @other_account = Account.create
            course_factory(active_all: true, account: @other_account)
            @other_course = @course
            @other_students = n_students_in_course(3, course: @other_course)
            teacher_in_course(active_all: true, course: @other_course, user: @me)
          end
          randos = @other_students.map { |cs| User.create!(id: cs.local_id) } # create a default shard user with a matching local id

          @user = @me
          api_call(:post,
                   "/api/v1/conversations",
                   { controller: "conversations", action: "create", format: "json" },
                   { recipients: @other_students.map(&:id),
                     body: "test",
                     context_code: "course_#{@other_course.id}",
                     group_conversation: "1",
                     bulk_message: "1",
                     mode: "async" })
          run_jobs
          batch = @shard1.activate { ConversationBatch.last }
          expect(batch).to be_sent
          randos.each { |r| expect(r.conversations).to be_empty }
          @other_students.each { |s| expect(s.conversations.last.conversation.shard).to eq @shard1 }
        end

        it "works cross-shard with local file" do
          @shard1.activate do
            @other_account = Account.create
            course_factory(active_all: true, account: @other_account)
            @other_course = @course
            @other_student = user_with_pseudonym(active_all: true, account: @other_account)
            @other_course.enroll_student(@other_student, enrollment_state: "active")
            teacher_in_course(active_all: true, course: @other_course, user: @me)
          end

          attachment = attachment_model(context: @me, folder: @me.conversation_attachments_folder)
          @user = @me

          api_call(:post,
                   "/api/v1/conversations",
                   { controller: "conversations", action: "create", format: "json" },
                   { recipients: [@other_student.id],
                     body: "yep",
                     context_code: "course_#{@other_course.id}",
                     course: "course_#{@other_course.id}",
                     group_conversation: "1",
                     bulk_message: "1",
                     mode: "async",
                     attachment_ids: [attachment.id] })
          run_jobs
          expect(@other_student.conversations.last.conversation.conversation_messages.last.attachment_ids).to eq [attachment.global_id]
        end
      end
    end
  end

  context "conversation" do
    context "with double testing of verifiers in returned url" do
      before do
        @attachment = @me.conversation_attachments_folder.attachments.create!(context: @me, filename: "test.txt", display_name: "test.txt", uploaded_data: StringIO.new("test"))
      end

      double_testing_with_disable_adding_uuid_verifier_in_api_ff do
        it "returns the conversation" do
          conversation = conversation(@bob, context_type: "Course", context_id: @course.id)
          media_object = MediaObject.new
          media_object.media_id = "0_12345678"
          media_object.media_type = "audio"
          media_object.context = @me
          media_object.user = @me
          media_object.title = "test title"
          media_object.save!
          conversation.add_message("another", attachment_ids: [@attachment.id], media_comment: media_object)

          conversation.reload

          json = api_call(:get,
                          "/api/v1/conversations/#{conversation.conversation_id}",
                          { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, format: "json" })
          json.delete("avatar_url")
          json["participants"].each do |p|
            p.delete("avatar_url")
          end
          json["messages"].each { |m| m["participating_user_ids"].sort! }
          json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
          expect(json).to eql({
                                "id" => conversation.conversation_id,
                                "subject" => nil,
                                "workflow_state" => "read",
                                "last_message" => "another",
                                "last_message_at" => conversation.last_message_at.to_json[1, 20],
                                "last_authored_message" => "another",
                                # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                                "message_count" => 2,
                                "subscribed" => true,
                                "private" => true,
                                "starred" => false,
                                "properties" => %w[last_author attachments media_objects],
                                "visible" => true,
                                "audience" => [@bob.id],
                                "audience_contexts" => {
                                  "groups" => {},
                                  "courses" => { @course.id.to_s => ["StudentEnrollment"] }
                                },
                                "participants" => [
                                  { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                                  { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                                ],
                                "messages" => [
                                  {
                                    "id" => conversation.messages.first.id,
                                    "created_at" => conversation.messages.first.created_at.to_json[1, 20],
                                    "body" => "another",
                                    "author_id" => @me.id,
                                    "generated" => false,
                                    "media_comment" => {
                                      "media_type" => "audio",
                                      "media_id" => "0_12345678",
                                      "display_name" => "test title",
                                      "content-type" => "audio/mp4",
                                      "url" => "http://www.example.com/users/#{@me.id}/media_download?entryId=0_12345678&redirect=1&type=mp4"
                                    },
                                    "forwarded_messages" => [],
                                    "attachments" => [
                                      {
                                        "filename" => "test.txt",
                                        "url" => "http://www.example.com/files/#{@attachment.id}/download?download_frd=1#{"&verifier=#{@attachment.uuid}" unless disable_adding_uuid_verifier_in_api}",
                                        "content-type" => "text/plain",
                                        "display_name" => "test.txt",
                                        "id" => @attachment.id,
                                        "folder_id" => @attachment.folder_id,
                                        "size" => @attachment.size,
                                        "unlock_at" => nil,
                                        "locked" => false,
                                        "hidden" => false,
                                        "lock_at" => nil,
                                        "locked_for_user" => false,
                                        "hidden_for_user" => false,
                                        "created_at" => @attachment.created_at.as_json,
                                        "updated_at" => @attachment.updated_at.as_json,
                                        "upload_status" => "success",
                                        "thumbnail_url" => nil,
                                        "modified_at" => @attachment.modified_at.as_json,
                                        "mime_class" => @attachment.mime_class,
                                        "media_entry_id" => @attachment.media_entry_id,
                                        "category" => "uncategorized"
                                      }
                                    ],
                                    "participating_user_ids" => [@me.id, @bob.id].sort
                                  },
                                  { "id" => conversation.messages.last.id, "created_at" => conversation.messages.last.created_at.to_json[1, 20], "body" => "test", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @bob.id].sort }
                                ],
                                "submissions" => [],
                                "context_name" => conversation.context_name,
                                "context_code" => conversation.conversation.context_code,
                              })
        end
      end
    end

    it "when file_association_access feature flag is enabled, it adds location tag to attachment url" do
      attachment = @me.conversation_attachments_folder.attachments.create!(context: @me, filename: "test.txt", display_name: "test.txt", uploaded_data: StringIO.new("test"))
      attachment.root_account.enable_feature!(:file_association_access)
      conversation = conversation(@bob, context_type: "Course", context_id: @course.id)
      media_object = MediaObject.new
      media_object.media_id = "0_12345678"
      media_object.media_type = "audio"
      media_object.context = @me
      media_object.user = @me
      media_object.title = "test title"
      media_object.save!
      message_with_attachment = conversation.add_message("another", attachment_ids: [attachment.id], media_comment: media_object)

      conversation.reload

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, format: "json" })

      attachment_url = json["messages"].first["attachments"].first["url"]
      media_comment_url = json["messages"].first["media_comment"]["url"]

      expect(attachment_url).to include("location=#{message_with_attachment.asset_string}")
      expect(media_comment_url).to include("location=#{message_with_attachment.asset_string}")
      expect(attachment_url).not_to include("verifier=#{attachment.uuid}")
    end

    it "when file_association_access feature flag is disabled, it adds verifier tag to attachment url" do
      attachment = @me.conversation_attachments_folder.attachments.create!(context: @me, filename: "test.txt", display_name: "test.txt", uploaded_data: StringIO.new("test"))
      attachment.root_account.disable_feature!(:disable_adding_uuid_verifier_in_api)
      conversation = conversation(@bob, context_type: "Course", context_id: @course.id)
      media_object = MediaObject.new
      media_object.media_id = "0_12345678"
      media_object.media_type = "audio"
      media_object.context = @me
      media_object.user = @me
      media_object.title = "test title"
      media_object.save!
      message_with_attachment = conversation.add_message("another", attachment_ids: [attachment.id], media_comment: media_object)

      conversation.reload

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, format: "json" })

      attachment_url = json["messages"].first["attachments"].first["url"]
      media_comment_url = json["messages"].first["media_comment"]["url"]

      expect(attachment_url).not_to include("location=#{message_with_attachment.asset_string}")
      expect(media_comment_url).not_to include("location=#{message_with_attachment.asset_string}")
      expect(attachment_url).to include("verifier=#{attachment.uuid}")
    end

    it "indicates if conversation permissions for the context are missing" do
      @user = @billy
      conversation = conversation(@bob, sender: @billy, context_type: "Course", context_id: @course.id)

      @course.account.role_overrides.create!(permission: :send_messages, role: student_role, enabled: false)

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, format: "json" })

      expect(json["cannot_reply"]).to be true
    end

    context "as an observer" do
      before :once do
        @bobs_mom = observer_in_course(name: "bob's mom", associated_user: @bob)
        @user = @bobs_mom
      end

      it "does not set cannot_reply for observer observee relationship" do
        conversation = conversation(@bobs_mom, sender: @bob, context_type: "Course", context_id: @course.id)

        json = api_call(
          :get,
          "/api/v1/conversations/#{conversation.conversation_id}",
          { controller: "conversations",
            action: "show",
            id: conversation.conversation_id.to_s,
            format: "json" }
        )

        expect(json["cannot_reply"]).to be_nil
      end

      it "sets cannot_reply to true if non-observed student" do
        conversation = conversation(@bobs_mom, sender: @billy, context_type: "Course", context_id: @course.id)

        json = api_call(
          :get,
          "/api/v1/conversations/#{conversation.conversation_id}",
          { controller: "conversations",
            action: "show",
            id: conversation.conversation_id.to_s,
            format: "json" }
        )

        expect(json["cannot_reply"]).to be true
      end
    end

    it "does not explode on account group conversations" do
      @user = @billy
      group
      @group.add_user(@bob)
      @group.add_user(@billy)
      conversation = conversation(@bob, sender: @billy, context_type: "Group", context_id: @group.id)

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, format: "json" })

      expect(json["cannot_reply"]).to_not be_truthy
    end

    context "with testing verifiers with disable_adding_uuid_verifier_in_api ff" do
      before do
        @attachment = @me.conversation_attachments_folder.attachments.create!(context: @me, filename: "test.txt", display_name: "test.txt", uploaded_data: StringIO.new("test"))
      end

      double_testing_with_disable_adding_uuid_verifier_in_api_ff do
        it "still includes attachment verifiers when using session auth" do
          conversation = conversation(@bob)
          conversation.add_message("another", attachment_ids: [@attachment.id], media_comment: media_object)
          conversation.reload
          user_session(@user)
          get "/api/v1/conversations/#{conversation.conversation_id}"
          json = json_parse
          expect(json["messages"][0]["attachments"][0]["url"]).to eq "http://www.example.com/files/#{@attachment.id}/download?download_frd=1#{"&verifier=#{@attachment.uuid}" unless disable_adding_uuid_verifier_in_api}"
        end
      end
    end

    it "uses participant's last_message_at and not consult the most recent message" do
      expected_lma = "2012-12-21T12:42:00Z"
      conversation = conversation(@bob)
      conversation.last_message_at = Time.zone.parse(expected_lma)
      conversation.save!
      conversation.add_message("another test", update_for_sender: false)
      json = api_call(:get,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, format: "json" })
      expect(json["last_message_at"]).to eql expected_lma
    end

    context "sharding" do
      specs_require_sharding

      def check_conversation
        json = api_call(:get,
                        "/api/v1/conversations/#{@conversation.conversation_id}",
                        { controller: "conversations", action: "show", id: @conversation.conversation_id.to_s, format: "json" })
        json.delete("avatar_url")
        json["participants"].each do |p|
          p.delete("avatar_url")
        end
        json["messages"].each { |m| m["participating_user_ids"].sort! }
        json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
        expected = {
          "id" => @conversation.conversation_id,
          "subject" => nil,
          "workflow_state" => "read",
          "last_message" => "test",
          "last_message_at" => @conversation.last_message_at.to_json[1, 20],
          "last_authored_message" => "test",
          # "last_authored_message_at" => @conversation.last_message_at.to_json[1, 20],
          "message_count" => 1,
          "subscribed" => true,
          "private" => true,
          "starred" => false,
          "properties" => ["last_author"],
          "visible" => true,
          "audience" => [@bob.id],
          "audience_contexts" => {
            "groups" => {},
            "courses" => { @course.id.to_s => ["StudentEnrollment"] }
          },
          "participants" => [
            { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
            { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
          ],
          "messages" => [
            { "id" => @conversation.messages.last.id, "created_at" => @conversation.messages.last.created_at.to_json[1, 20], "body" => "test", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @bob.id].sort }
          ],
          "submissions" => [],
          "context_name" => @conversation.context_name,
          "context_code" => @conversation.conversation.context_code,
        }
        expect(json).to eq expected
      end

      it "shows ids relative to the current shard" do
        Setting.set("conversations_sharding_migration_still_running", "0")
        @conversation = @shard1.activate { conversation(@bob) }
        check_conversation
        @shard1.activate { check_conversation }
        @shard2.activate { check_conversation }
      end
    end

    it "auto-mark-as-reads if unread" do
      conversation = conversation(@bob, workflow_state: "unread")

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation.conversation_id}?scope=unread",
                      { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, scope: "unread", format: "json" })
      expect(json["visible"]).to be_falsey
      expect(conversation.reload).to be_read
    end

    it "does not auto-mark-as-read if auto_mark_as_read = false" do
      conversation = conversation(@bob, workflow_state: "unread")

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation.conversation_id}?scope=unread&auto_mark_as_read=0",
                      { controller: "conversations", action: "show", id: conversation.conversation_id.to_s, scope: "unread", auto_mark_as_read: "0", format: "json" })
      expect(json["visible"]).to be_truthy
      expect(conversation.reload).to be_unread
    end

    it "properly flags if starred in the response" do
      conversation1 = conversation(@bob)
      conversation2 = conversation(@billy, starred: true)

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation1.conversation_id}",
                      { controller: "conversations", action: "show", id: conversation1.conversation_id.to_s, format: "json" })
      expect(json["starred"]).to be_falsey

      json = api_call(:get,
                      "/api/v1/conversations/#{conversation2.conversation_id}",
                      { controller: "conversations", action: "show", id: conversation2.conversation_id.to_s, format: "json" })
      expect(json["starred"]).to be_truthy
    end

    it "does not link submission comments and conversations anymore" do
      submission1 = submission_model(course: @course, user: @bob)
      submission2 = submission_model(course: @course, user: @bob)
      conversation(@bob)
      submission1.add_comment(comment: "hey bob", author: @me)
      submission1.add_comment(comment: "wut up teacher", author: @bob)
      submission2.add_comment(comment: "my name is bob", author: @bob)

      json = api_call(:get,
                      "/api/v1/conversations/#{@conversation.conversation_id}",
                      { controller: "conversations", action: "show", id: @conversation.conversation_id.to_s, format: "json" })

      expect(json["messages"].size).to eq 1
      expect(json["submissions"].size).to eq 0
    end

    it "adds a message to the conversation" do
      conversation = conversation(@bob)

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_message",
                      { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
                      { body: "another" })
      conversation.reload
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json["messages"].each { |m| m["participating_user_ids"].sort! }
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => "another",
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "another",
                            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                            "message_count" => 2, # two messages total now, though we'll only get the latest one in the response
                            "subscribed" => true,
                            "private" => true,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "visible" => true,
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@bob.id],
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => ["StudentEnrollment"] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ],
                            "messages" => [
                              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "another", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @bob.id].sort }
                            ]
                          })
    end

    it "only adds participants for the new message to the given recipients" do
      conversation = conversation(@bob, private: false)

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_message",
                      { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
                      { body: "another", recipients: [@billy.id] })
      conversation.reload
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json["audience"].sort!
      json["messages"].each { |m| m["participating_user_ids"].sort! }
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => "another",
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "another",
                            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                            "message_count" => 2, # two messages total now, though we'll only get the latest one in the response
                            "subscribed" => true,
                            "private" => false,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "visible" => true,
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@bob.id, @billy.id].sort,
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => [] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ],
                            "messages" => [
                              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "another", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @billy.id].sort }
                            ]
                          })
    end

    it "returns an error if trying to add more participants than the maximum group size on add_message" do
      conversation = conversation(@bob, private: false)

      Setting.set("max_group_conversation_size", 1)

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_message",
                      { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
                      { body: "another", recipients: [@billy.id] },
                      {},
                      { expected_status: 400 })
      expect(json.first["message"]).to include("Too many participants for group conversation")
    end

    it "adds participants for the given messages to the given recipients" do
      conversation = conversation(@bob, private: false)
      message = conversation.add_message("another one")

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_message",
                      { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
                      { body: "partially hydrogenated context oils", recipients: [@billy.id], included_messages: [message.id] })
      conversation.reload
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json["audience"].sort!
      json["messages"].each { |m| m["participating_user_ids"].sort! }
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => "partially hydrogenated context oils",
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "partially hydrogenated context oils",
                            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                            "message_count" => 3,
                            "subscribed" => true,
                            "private" => false,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "visible" => true,
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@bob.id, @billy.id].sort,
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => [] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ],
                            "messages" => [
                              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "partially hydrogenated context oils", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @billy.id].sort }
                            ]
                          })
      message.reload
      expect(message.conversation_message_participants.where(user_id: @billy.id).exists?).to be_truthy
    end

    it "excludes participants that aren't in the recipient list" do
      conversation = conversation(@bob, @billy, private: false)
      message = conversation.add_message("another one")

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_message",
                      { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
                      { body: "partially hydrogenated context oils", recipients: [@billy.id], included_messages: [message.id] })
      conversation.reload
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json["audience"].sort!
      json["messages"].each { |m| m["participating_user_ids"].sort! }
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => "partially hydrogenated context oils",
                            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "partially hydrogenated context oils",
                            "message_count" => 3,
                            "subscribed" => true,
                            "private" => false,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "visible" => true,
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@bob.id, @billy.id].sort,
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => [] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ],
                            "messages" => [
                              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "partially hydrogenated context oils", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @billy.id].sort }
                            ]
                          })
      message.reload
      expect(message.conversation_message_participants.where(user_id: @billy.id).exists?).to be_truthy
    end

    it "adds message participants for all conversation participants (if recipients are not specified) to included messages only" do
      conversation = conversation(@bob, private: false)
      message = conversation.add_message("you're swell, @bob")

      api_call(:post,
               "/api/v1/conversations/#{conversation.conversation_id}/add_message",
               { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
               { body: "man, @bob sure does suck", recipients: [@billy.id] })
      # at this point, @billy can see ^^^ that message, but not the first one. @bob can't see ^^^ that one. everyone is a conversation participant now
      conversation.reload
      bob_sucks = conversation.conversation.conversation_messages.first

      # implicitly send to all the conversation participants, including the original message. this will let @billy see it
      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_message",
                      { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
                      { body: "partially hydrogenated context oils", included_messages: [message.id] })
      conversation.reload
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json["audience"].sort!
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
      json["messages"].each { |m| m["participating_user_ids"].sort! }
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => "partially hydrogenated context oils",
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "partially hydrogenated context oils",
                            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                            "message_count" => 4,
                            "subscribed" => true,
                            "private" => false,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "visible" => true,
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@bob.id, @billy.id].sort,
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => [] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ],
                            "messages" => [
                              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "partially hydrogenated context oils", "author_id" => @me.id, "generated" => false, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @bob.id, @billy.id].sort }
                            ]
                          })
      message.reload
      expect(message.conversation_message_participants.where(user_id: @billy.id).exists?).to be_truthy
      bob_sucks.reload
      expect(bob_sucks.conversation_message_participants.where(user_id: @billy.id).exists?).to be_truthy
      expect(bob_sucks.conversation_message_participants.where(user_id: @bob.id).exists?).to be_falsey
    end

    it "allows users to respond to admin initiated conversations" do
      account_admin_user active_all: true
      cp = conversation(@other, sender: @admin, private: false)
      real_conversation = cp.conversation
      real_conversation.context = Account.default
      real_conversation.save!

      @user = @other
      api_call(:post,
               "/api/v1/conversations/#{real_conversation.id}/add_message",
               { controller: "conversations", action: "add_message", id: real_conversation.id.to_s, format: "json" },
               { body: "ok", recipients: [@admin.id.to_s] })
      real_conversation.reload
      new_message = real_conversation.conversation_messages.first
      expect(new_message.conversation_message_participants.size).to eq 2
    end

    it "allows users to respond to anyone who is already a participant" do
      cp = conversation(@bob, @billy, @jane, @joe, sender: @bob)
      real_conversation = cp.conversation
      real_conversation.context = @course
      real_conversation.save!

      @joe.enrollments.each(&:destroy)
      @user = @billy
      api_call(:post,
               "/api/v1/conversations/#{real_conversation.id}/add_message",
               { controller: "conversations", action: "add_message", id: real_conversation.id.to_s, format: "json" },
               { body: "ok", recipients: [@bob, @billy, @jane, @joe].map { |u| u.id.to_s } })
      real_conversation.reload
      new_message = real_conversation.conversation_messages.first
      expect(new_message.conversation_message_participants.size).to eq 4
    end

    it "creates a media object if it doesn't exist" do
      conversation = conversation(@bob)

      expect(MediaObject.count).to be 0
      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_message",
                      { controller: "conversations", action: "add_message", id: conversation.conversation_id.to_s, format: "json" },
                      { body: "another", media_comment_id: "asdf", media_comment_type: "audio" })
      conversation.reload
      mjson = json["messages"][0]["media_comment"]
      expect(mjson).to be_present
      expect(mjson["media_id"]).to eql "asdf"
      expect(mjson["media_type"]).to eql "audio"
      expect(MediaObject.count).to be 1
    end

    it "adds recipients to the conversation" do
      conversation = conversation(@bob, @billy)

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_recipients",
                      { controller: "conversations", action: "add_recipients", id: conversation.conversation_id.to_s, format: "json" },
                      { recipients: [@jane.id.to_s, "course_#{@course.id}"] })
      conversation.reload
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json["messages"].each { |m| m["participating_user_ids"].sort! }
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => "test",
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "test",
                            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                            "message_count" => 1,
                            "subscribed" => true,
                            "private" => false,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "context_code" => conversation.conversation.context_code,
                            "visible" => true,
                            "audience" => [@billy.id, @bob.id, @jane.id, @joe.id, @tommy.id],
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => [] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @jane.id, "pronouns" => nil, "name" => @jane.short_name, "full_name" => @jane.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @joe.id, "pronouns" => nil, "name" => @joe.short_name, "full_name" => @joe.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @tommy.id, "pronouns" => nil, "name" => @tommy.short_name, "full_name" => @tommy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ],
                            "messages" => [
                              { "id" => conversation.messages.first.id, "created_at" => conversation.messages.first.created_at.to_json[1, 20], "body" => "jane, joe, and tommy were added to the conversation by nobody@example.com", "author_id" => @me.id, "generated" => true, "media_comment" => nil, "forwarded_messages" => [], "attachments" => [], "participating_user_ids" => [@me.id, @billy.id, @bob.id, @jane.id, @joe.id, @tommy.id].sort }
                            ]
                          })
    end

    it "returns an error if trying to add more participants than the maximum group size on add_recipients" do
      conversation = conversation(@bob, @billy, @joe)

      Setting.set("max_group_conversation_size", 2)

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/add_recipients",
                      { controller: "conversations", action: "add_recipients", id: conversation.conversation_id.to_s, format: "json" },
                      { recipients: [@jane.id.to_s, "course_#{@course.id}"] },
                      {},
                      { expected_status: 400 })
      expect(json.first["message"]).to include("too many participants")
    end

    it "does not cache an old audience when adding recipients" do
      enable_cache do
        Timecop.freeze(5.seconds.ago) do
          @conversation = conversation(@bob, @billy)
          # prime the paticipants cache
          @conversation.participants
        end

        json = api_call(:post,
                        "/api/v1/conversations/#{@conversation.conversation_id}/add_recipients",
                        { controller: "conversations", action: "add_recipients", id: @conversation.conversation_id.to_s, format: "json" },
                        { recipients: [@jane.id.to_s, "course_#{@course.id}"] })
        expect(json["audience"]).to match_array [@billy.id, @bob.id, @jane.id, @joe.id, @tommy.id]
      end
    end

    it "updates the conversation" do
      conversation = conversation(@bob, @billy)

      json = api_call(:put,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "update", id: conversation.conversation_id.to_s, format: "json" },
                      { conversation: { subscribed: false, workflow_state: "archived" } })
      conversation.reload
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "archived",
                            "last_message" => "test",
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "test",
                            # "last_authored_message_at" => conversation.last_authored_at.to_json[1, 20],
                            "message_count" => 1,
                            "subscribed" => false,
                            "private" => false,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "visible" => false, # since we archived it, and the default view is assumed
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@billy.id, @bob.id],
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => [] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @billy.id, "pronouns" => nil, "name" => @billy.short_name, "full_name" => @billy.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ]
                          })
    end

    it "is able to star the conversation via update" do
      conversation = conversation(@bob, @billy)

      json = api_call(:put,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "update", id: conversation.conversation_id.to_s, format: "json" },
                      { conversation: { starred: true } })
      expect(json["starred"]).to be_truthy
    end

    it "is able to unstar the conversation via update" do
      conversation = conversation(@bob, @billy, starred: true)

      json = api_call(:put,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "update", id: conversation.conversation_id.to_s, format: "json" },
                      { conversation: { starred: false } })
      expect(json["starred"]).to be_falsey
    end

    it "leaves starryness alone when left out of update" do
      conversation = conversation(@bob, @billy, starred: true)

      json = api_call(:put,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "update", id: conversation.conversation_id.to_s, format: "json" },
                      { conversation: { workflow_state: "read" } })
      expect(json["starred"]).to be_truthy
    end

    it "deletes messages from the conversation" do
      conversation = conversation(@bob)
      message = conversation.add_message("another one")

      json = api_call(:post,
                      "/api/v1/conversations/#{conversation.conversation_id}/remove_messages",
                      { controller: "conversations", action: "remove_messages", id: conversation.conversation_id.to_s, format: "json" },
                      { remove: [message.id] })
      conversation.reload
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      json.delete("last_authored_message_at") # This is sometimes not updated. It's a known bug.

      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => "test",
                            "last_message_at" => conversation.last_message_at.to_json[1, 20],
                            "last_authored_message" => "test",
                            # "last_authored_message_at" => conversation.last_authored_message.created_at.to_json[1, 20],
                            "message_count" => 1,
                            "subscribed" => true,
                            "private" => true,
                            "starred" => false,
                            "properties" => ["last_author"],
                            "visible" => true,
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@bob.id],
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => { @course.id.to_s => ["StudentEnrollment"] }
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ]
                          })
    end

    it "deletes the conversation" do
      conversation = conversation(@bob)

      json = api_call(:delete,
                      "/api/v1/conversations/#{conversation.conversation_id}",
                      { controller: "conversations", action: "destroy", id: conversation.conversation_id.to_s, format: "json" })
      json.delete("avatar_url")
      json["participants"].each do |p|
        p.delete("avatar_url")
      end
      expect(json).to eql({
                            "id" => conversation.conversation_id,
                            "subject" => nil,
                            "workflow_state" => "read",
                            "last_message" => nil,
                            "last_message_at" => nil,
                            "last_authored_message" => nil,
                            "last_authored_message_at" => nil,
                            "message_count" => 0,
                            "subscribed" => true,
                            "private" => true,
                            "starred" => false,
                            "properties" => [],
                            "visible" => false,
                            "context_code" => conversation.conversation.context_code,
                            "audience" => [@bob.id],
                            "audience_contexts" => {
                              "groups" => {},
                              "courses" => {} # tags, and by extension audience_contexts, get cleared out when the conversation is deleted
                            },
                            "participants" => [
                              { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => {}, "common_groups" => {} },
                              { "id" => @bob.id, "pronouns" => nil, "name" => @bob.short_name, "full_name" => @bob.name, "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
                            ]
                          })
    end
  end

  context "recipients" do
    before :once do
      @group = @course.groups.create(name: "the group")
      @group.users = [@me, @bob, @joe]
    end

    it "supports the deprecated route" do
      json = api_call(:get,
                      "/api/v1/conversations/find_recipients.json?search=o",
                      { controller: "search", action: "recipients", format: "json", search: "o" })
      json.each { |c| c.delete("avatar_url") }
      expect(json).to eql [
        { "id" => "course_#{@course.id}", "name" => "the course", "type" => "context", "user_count" => 6, "permissions" => {} },
        { "id" => "section_#{@other_section.id}", "name" => "the other section", "type" => "context", "user_count" => 1, "permissions" => {}, "context_name" => "the course" },
        { "id" => "section_#{@course.default_section.id}", "name" => "the section", "type" => "context", "user_count" => 5, "permissions" => {}, "context_name" => "the course" },
        { "id" => "group_#{@group.id}", "name" => "the group", "type" => "context", "user_count" => 3, "permissions" => {}, "context_name" => "the course" },
        { "id" => @joe.id, "pronouns" => nil, "name" => "joe", "full_name" => "joe", "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => { @group.id.to_s => ["Member"] } },
        { "id" => @me.id, "pronouns" => nil, "name" => @me.short_name, "full_name" => @me.name, "common_courses" => { @course.id.to_s => ["TeacherEnrollment"] }, "common_groups" => { @group.id.to_s => ["Member"] } },
        { "id" => @bob.id, "pronouns" => nil, "name" => "bob", "full_name" => "bob smith", "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => { @group.id.to_s => ["Member"] } },
        { "id" => @tommy.id, "pronouns" => nil, "name" => "tommy", "full_name" => "tommy", "common_courses" => { @course.id.to_s => ["StudentEnrollment"] }, "common_groups" => {} }
      ]
    end
  end

  context "batches" do
    it "returns all in-progress batches" do
      batch1 = ConversationBatch.generate(Conversation.build_message(@me, "hi all"), [@bob, @billy], :async)
      ConversationBatch.generate(Conversation.build_message(@me, "ohai"), [@bob, @billy], :sync)
      ConversationBatch.generate(Conversation.build_message(@bob, "sup"), [@me, @billy], :async)

      json = api_call(:get,
                      "/api/v1/conversations/batches",
                      controller: "conversations",
                      action: "batches",
                      format: "json")

      expect(json.size).to be 1 # batch2 already ran, batch3 belongs to someone else
      expect(json[0]["id"]).to eql batch1.id
    end
  end

  describe "visibility inference" do
    it "does not break with empty string as filter" do
      # added for 1.9.3
      json = api_call(:post,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "create", format: "json" },
                      { recipients: [@bob.id], body: "Test Message", filter: "" })
      expect(json.first["visible"]).to be_falsey
    end
  end

  describe "bulk updates" do
    let_once(:c1) { conversation(@me, @bob, workflow_state: "unread") }
    let_once(:c2) { conversation(@me, @jane, workflow_state: "read") }
    let_once(:conversation_ids) { [c1, c2].map { |c| c.conversation.id } }

    it "marks conversations as read" do
      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "mark_as_read", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      expect(c1.reload).to be_read
      expect(c2.reload).to be_read
      expect(@me.reload.unread_conversations_count).to be(0)
    end

    it "marks conversations as unread" do
      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "mark_as_unread", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      expect(c1.reload).to be_unread
      expect(c2.reload).to be_unread
      expect(@me.reload.unread_conversations_count).to be(2)
    end

    it "marks conversations as starred" do
      c1.update_attribute :starred, true

      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "star", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      expect(c1.reload.starred).to be_truthy
      expect(c2.reload.starred).to be_truthy
      expect(@me.reload.unread_conversations_count).to be(1)
    end

    it "marks conversations as unstarred" do
      c1.update_attribute :starred, true

      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "unstar", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      expect(c1.reload.starred).to be_falsey
      expect(c2.reload.starred).to be_falsey
      expect(@me.reload.unread_conversations_count).to be(1)
    end

    # it "should mark conversations as subscribed"
    # it "should mark conversations as unsubscribed"
    it "archives conversations" do
      conversations = %w[archived read unread].map do |state|
        conversation(@me, @bob, workflow_state: state)
      end
      expect(@me.reload.unread_conversations_count).to be(1)

      conversation_ids = conversations.map { |c| c.conversation.id }
      allow(InstStatsd::Statsd).to receive(:count)
      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "archive", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      conversations.each do |c|
        expect(c.reload).to be_archived
      end
      expect(InstStatsd::Statsd).to have_received(:count).with("inbox.conversation.archived.legacy", 3)
      expect(InstStatsd::Statsd).not_to have_received(:count).with("inbox.conversation.archived.react")
      expect(@me.reload.unread_conversations_count).to be(0)
    end

    it "unarchives conversations by marking as read" do
      conversations = %w[archived archived archived].map do |state|
        conversation(@me, @bob, workflow_state: state)
      end

      conversation_ids = conversations.map { |c| c.conversation.id }
      allow(InstStatsd::Statsd).to receive(:distributed_increment)
      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "mark_as_read", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("inbox.conversation.unarchived.legacy")
    end

    it "unarchives conversations by marking as unread" do
      conversations = %w[archived archived archived].map do |state|
        conversation(@me, @bob, workflow_state: state)
      end

      conversation_ids = conversations.map { |c| c.conversation.id }
      allow(InstStatsd::Statsd).to receive(:distributed_increment)
      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "mark_as_unread", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      expect(InstStatsd::Statsd).to have_received(:distributed_increment).with("inbox.conversation.unarchived.legacy")
    end

    it "destroys conversations" do
      json = api_call(:put,
                      "/api/v1/conversations",
                      { controller: "conversations", action: "batch_update", format: "json" },
                      { event: "destroy", conversation_ids: })
      run_jobs
      progress = Progress.find(json["id"])
      expect(progress.message.to_s).to include "#{conversation_ids.size} conversations processed"
      expect(c1.reload.messages).to be_empty
      expect(c2.reload.messages).to be_empty
      expect(@me.reload.unread_conversations_count).to be(0)
    end

    describe "immediate failures" do
      it "fails if event is invalid" do
        json = api_call(:put,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "batch_update", format: "json" },
                        { event: "NONSENSE", conversation_ids: },
                        {},
                        { expected_status: 400 })

        expect(json["message"]).to include "invalid event"
      end

      it "fails if event parameter is not specified" do
        json = api_call(:put,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "batch_update", format: "json" },
                        { conversation_ids: },
                        {},
                        { expected_status: 400 })

        expect(json["message"]).to include "event not specified"
      end

      it "fails if conversation_ids is not specified" do
        json = api_call(:put,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "batch_update", format: "json" },
                        { event: "mark_as_read" },
                        {},
                        { expected_status: 400 })

        expect(json["message"]).to include "conversation_ids not specified"
      end

      it "fails if batch size limit is exceeded" do
        conversation_ids = (1..501).to_a
        json = api_call(:put,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "batch_update", format: "json" },
                        { event: "mark_as_read", conversation_ids: },
                        {},
                        { expected_status: 400 })
        expect(json["message"]).to include "exceeded"
      end
    end

    describe "progress" do
      it "creates and update a progress object" do
        json = api_call(:put,
                        "/api/v1/conversations",
                        { controller: "conversations", action: "batch_update", format: "json" },
                        { event: "mark_as_read", conversation_ids: })
        progress = Progress.find(json["id"])
        expect(progress).to be_present
        expect(progress).to be_queued
        expect(progress.completion).to be(0.0)
        run_jobs
        expect(progress.reload).to be_completed
        expect(progress.completion).to be(100.0)
      end

      describe "progress failures" do
        it "does not update conversations the current user does not participate in" do
          c3 = conversation(@bob, @jane, sender: @bob, workflow_state: "unread")
          conversation_ids = [c1, c2, c3].map { |c| c.conversation.id }

          json = api_call(:put,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "batch_update", format: "json" },
                          { event: "mark_as_read", conversation_ids: })
          run_jobs
          progress = Progress.find(json["id"])
          expect(progress).to be_completed
          expect(progress.completion).to be(100.0)
          expect(c1.reload).to be_read
          expect(c2.reload).to be_read
          expect(c3.reload).to be_unread
          expect(progress.message).to include "not participating"
          expect(progress.message).to include "2 conversations processed"
        end

        it "fails if all conversation ids are invalid" do
          c1 = conversation(@bob, @jane, sender: @bob, workflow_state: "unread")
          conversation_ids = [c1.conversation.id]

          json = api_call(:put,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "batch_update", format: "json" },
                          { event: "mark_as_read", conversation_ids: })

          run_jobs
          progress = Progress.find(json["id"])
          expect(progress).to be_failed
          expect(progress.completion).to be(100.0)
          expect(c1.reload).to be_unread
          expect(progress.message).to include "not participating"
          expect(progress.message).to include "0 conversations processed"
        end

        it "fails progress if exception is raised in job" do
          allow_any_instance_of(Progress).to receive(:complete!).and_raise "crazy exception"

          c1 = conversation(@me, @jane, workflow_state: "unread")
          conversation_ids = [c1.conversation.id]
          json = api_call(:put,
                          "/api/v1/conversations",
                          { controller: "conversations", action: "batch_update", format: "json" },
                          { event: "mark_as_read", conversation_ids: })
          run_jobs
          progress = Progress.find(json["id"])
          expect(progress).to be_failed
          expect(progress.message).to include "crazy exception"
        end
      end
    end
  end

  describe "delete_for_all" do
    it "requires site_admin with manage_students permissions" do
      cp = conversation(@me, @bob, @billy, @jane, @joe, @tommy, sender: @me)
      conv = cp.conversation
      expect(@joe.conversations.size).to be 1

      account_admin_user_with_role_changes(account: Account.site_admin, role_changes: { manage_students: false })
      raw_api_call(:delete,
                   "/api/v1/conversations/#{conv.id}/delete_for_all",
                   { controller: "conversations", action: "delete_for_all", format: "json", id: conv.id.to_s },
                   { domain_root_account: Account.site_admin })
      assert_forbidden

      account_admin_user
      Account.default.pseudonyms.create!(unique_id: "admin", user: @user)
      raw_api_call(:delete,
                   "/api/v1/conversations/#{conv.id}/delete_for_all",
                   { controller: "conversations", action: "delete_for_all", format: "json", id: conv.id.to_s },
                   {})
      assert_forbidden

      @user = @me
      raw_api_call(:delete,
                   "/api/v1/conversations/#{conv.id}/delete_for_all",
                   { controller: "conversations", action: "delete_for_all", format: "json", id: conv.id.to_s },
                   {})
      assert_forbidden

      expect(@me.all_conversations.size).to be 1
      expect(@joe.conversations.size).to be 1
    end

    it "fails if conversation doesn't exist" do
      site_admin_user
      raw_api_call(:delete,
                   "/api/v1/conversations/0/delete_for_all",
                   { controller: "conversations", action: "delete_for_all", format: "json", id: "0" },
                   {})
      assert_status(404)
    end

    it "deletes the conversation for all participants" do
      users = [@me, @bob, @billy, @jane, @joe, @tommy]
      cp = conversation(*users)
      conv = cp.conversation
      users.each do |user|
        expect(user.all_conversations.size).to be 1
        expect(user.stream_item_instances.size).to be 1 unless user.id == @me.id
      end

      site_admin_user
      json = api_call(:delete,
                      "/api/v1/conversations/#{conv.id}/delete_for_all",
                      { controller: "conversations", action: "delete_for_all", format: "json", id: conv.id.to_s },
                      {})

      expect(json).to eql({})

      users.each do |user|
        expect(user.reload.all_conversations.size).to be 0
        expect(user.stream_item_instances.size).to be 0
      end
      expect(ConversationParticipant.count).to be 0
      expect(ConversationMessageParticipant.count).to be 0
      # should leave the conversation and its message in the database
      expect(Conversation.count).to be 1
      expect(ConversationMessage.count).to be 1
    end

    context "sharding" do
      specs_require_sharding

      it "deletes the conversation for users on multiple shards" do
        users = [@me]
        users << @shard1.activate { User.create! }

        cp = conversation(*users)
        conv = cp.conversation
        users.each do |user|
          expect(user.all_conversations.size).to be 1
          expect(user.stream_item_instances.size).to be 1 unless user.id == @me.id
        end

        site_admin_user
        @shard2.activate do
          json = api_call(:delete,
                          "/api/v1/conversations/#{conv.id}/delete_for_all",
                          { controller: "conversations", action: "delete_for_all", format: "json", id: conv.id.to_s },
                          {})

          expect(json).to eql({})
        end

        users.each do |user|
          expect(user.reload.all_conversations.size).to be 0
          expect(user.stream_item_instances.size).to be 0
        end
        expect(ConversationParticipant.count).to be 0
        expect(ConversationMessageParticipant.count).to be 0
        # should leave the conversation and its message in the database
        expect(Conversation.count).to be 1
        expect(ConversationMessage.count).to be 1
      end
    end
  end

  describe "unread_count" do
    it "returns the number of unread conversations for the current user" do
      conversation(student_in_course, workflow_state: "unread")
      json = api_call(:get,
                      "/api/v1/conversations/unread_count.json",
                      { controller: "conversations", action: "unread_count", format: "json" })
      expect(json).to eql({ "unread_count" => "1" })
    end
  end

  context "deleted_conversations" do
    before :once do
      @me = nil
      @c1 = conversation(@bob)
      @c1.remove_messages(:all)

      @c2 = conversation(@billy)
      @c2.remove_messages(:all)

      account_admin_user(account: Account.site_admin)
    end

    it "returns a list of deleted conversation messages" do
      json = api_call(:get,
                      "/api/v1/conversations/deleted",
                      { controller: "conversations",
                        action: "deleted_index",
                        format: "json",
                        user_id: @bob.id })

      expect(json.count).to be 1
      expect(json[0]).to include(
        "attachments",
        "body",
        "author_id",
        "conversation_id",
        "created_at",
        "deleted_at",
        "forwarded_messages",
        "generated",
        "id",
        "media_comment",
        "participating_user_ids",
        "user_id"
      )
    end

    it "returns a paginated response with proper link headers" do
      api_call(:get,
               "/api/v1/conversations/deleted",
               { controller: "conversations",
                 action: "deleted_index",
                 format: "json",
                 user_id: @bob.id })

      links = response.headers["Link"].split(",")
      expect(links.all? { |l| l.include?("api/v1/conversations/deleted") }).to be_truthy
      expect(links.find { |l| l.include?('rel="current"') }).to match(/page=1&per_page=10>/)
      expect(links.find { |l| l.include?('rel="first"') }).to match(/page=1&per_page=10>/)
      expect(links.find { |l| l.include?('rel="last"') }).to match(/page=1&per_page=10>/)
    end

    it "can respond with multiple users data" do
      json = api_call(:get,
                      "/api/v1/conversations/deleted",
                      { controller: "conversations",
                        action: "deleted_index",
                        format: "json",
                        user_id: [@bob.id, @billy.id] })

      expect(json.count).to be 2
    end

    it "will only get the provided conversation id" do
      json = api_call(:get,
                      "/api/v1/conversations/deleted",
                      { controller: "conversations",
                        action: "deleted_index",
                        format: "json",
                        user_id: [@bob.id, @billy.id],
                        conversation_id: @c1.conversation_id })

      expect(json.count).to be 1
    end

    it "can filter based on the deletion date" do
      json = api_call(:get,
                      "/api/v1/conversations/deleted",
                      { controller: "conversations",
                        action: "deleted_index",
                        format: "json",
                        user_id: @bob.id,
                        deleted_before: 1.hour.from_now })
      expect(json.count).to be 1

      json = api_call(:get,
                      "/api/v1/conversations/deleted",
                      { controller: "conversations",
                        action: "deleted_index",
                        format: "json",
                        user_id: @bob.id,
                        deleted_before: 1.hour.ago })
      expect(json.count).to be 0

      json = api_call(:get,
                      "/api/v1/conversations/deleted",
                      { controller: "conversations",
                        action: "deleted_index",
                        format: "json",
                        user_id: @bob.id,
                        deleted_after: 1.hour.ago })
      expect(json.count).to be 1

      json = api_call(:get,
                      "/api/v1/conversations/deleted",
                      { controller: "conversations",
                        action: "deleted_index",
                        format: "json",
                        user_id: @bob.id,
                        deleted_after: 1.hour.from_now })
      expect(json.count).to be 0
    end
  end

  context "restore_message" do
    before :once do
      @me = nil
      @c1 = conversation(@bob)

      account_admin_user(account: Account.site_admin)
    end

    before do
      @c1.remove_messages(:all)
      @c1.message_count = 0
      @c1.last_message_at = nil
      @c1.save!
    end

    it "returns an error when the conversation_message_id is not provided" do
      @c1.all_messages.first

      raw_api_call(:put,
                   "/api/v1/conversations/restore",
                   { controller: "conversations",
                     action: "restore_message",
                     format: "json",
                     user_id: @bob.id,
                     conversation_id: @c1.conversation_id })

      expect(response).to have_http_status :bad_request
    end

    it "returns an error when the user_id is not provided" do
      message = @c1.all_messages.first

      raw_api_call(:put,
                   "/api/v1/conversations/restore",
                   { controller: "conversations",
                     action: "restore_message",
                     format: "json",
                     conversation_id: @c1.conversation_id,
                     conversation_message_id: message.id })

      expect(response).to have_http_status :bad_request
    end

    it "returns an error when the conversation_id is not provided" do
      message = @c1.all_messages.first

      raw_api_call(:put,
                   "/api/v1/conversations/restore",
                   { controller: "conversations",
                     action: "restore_message",
                     format: "json",
                     user_id: @bob.id,
                     conversation_message_id: message.id })

      expect(response).to have_http_status :bad_request
    end

    it "restores the message" do
      message = @c1.all_messages.first

      api_call(:put,
               "/api/v1/conversations/restore",
               { controller: "conversations",
                 action: "restore_message",
                 format: "json",
                 user_id: @bob.id,
                 message_id: message.id,
                 conversation_id: @c1.conversation_id })

      expect(response).to have_http_status :ok

      cmp = ConversationMessageParticipant.where(user_id: @bob.id).where(conversation_message_id: message.id).first
      expect(cmp.workflow_state).to eql "active"
      expect(cmp.deleted_at).to be_nil
    end

    it "updates the message count and last_message_at on the conversation" do
      expect(@c1.message_count).to be 0
      expect(@c1.last_message_at).to be_nil

      message = @c1.all_messages.first

      api_call(:put,
               "/api/v1/conversations/restore",
               { controller: "conversations",
                 action: "restore_message",
                 format: "json",
                 user_id: @bob.id,
                 message_id: message.id,
                 conversation_id: @c1.conversation_id })

      expect(response).to have_http_status :ok

      @c1.reload
      expect(@c1.message_count).to be 1
      expect(@c1.last_message_at).to eql message.created_at
    end
  end
end
