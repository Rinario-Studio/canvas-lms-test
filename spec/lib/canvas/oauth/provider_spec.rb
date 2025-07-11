# frozen_string_literal: true

#
# Copyright (C) 2012 - present Instructure, Inc.
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

module Canvas::OAuth
  describe Provider do
    let(:provider) { Provider.new("123") }

    def stub_dev_key(key)
      allow(DeveloperKey).to receive(:find_cached).and_return(key)
    end

    describe "initialization" do
      it "retains the client_id" do
        expect(provider.client_id).to eq "123"
      end

      it "defaults the redirect_uri to a blank string" do
        expect(provider.redirect_uri).to eq ""
      end

      it "can override the default redirect_uri" do
        expect(Provider.new("123", "456").redirect_uri).to eq "456"
      end
    end

    describe "#code_challenge" do
      it "returns the code_challenge when pkce is set" do
        provider = Provider.new("123", "", [], nil, pkce: { code_challenge: "challenge" })
        expect(provider.code_challenge).to eq "challenge"
      end

      it "returns nil when pkce is not set" do
        provider = Provider.new("123")
        expect(provider.code_challenge).to be_nil
      end
    end

    describe "#code_challenge_method" do
      it "returns the code_challenge_method when pkce is set" do
        provider = Provider.new("123", "", [], nil, pkce: { code_challenge_method: "S256" })
        expect(provider.code_challenge_method).to eq "S256"
      end

      it "returns nil when pkce is not set" do
        provider = Provider.new("123")
        expect(provider.code_challenge_method).to be_nil
      end
    end

    describe "#has_valid_key?" do
      it "is true when there is a key and the key is active" do
        stub_dev_key(double(active?: true))
        expect(provider.has_valid_key?).to be_truthy
      end

      it "is false when there is a key that is not active" do
        stub_dev_key(double(active?: false))
        expect(provider.has_valid_key?).to be_falsey
      end

      it "is false when there is no key" do
        stub_dev_key(nil)
        expect(provider.has_valid_key?).to be_falsey
      end
    end

    describe "#client_id_is_valid?" do
      it "is false for a nil id" do
        expect(Provider.new(nil, "456").client_id_is_valid?).to be_falsey
      end

      it "is false for a non-integer" do
        expect(Provider.new("XXXXX", "456").client_id_is_valid?).to be_falsey
      end

      it "is true for an integer" do
        expect(Provider.new("123", "456").client_id_is_valid?).to be_truthy
      end

      it "is true for minimum 64-bit integer value" do
        min_64bit = -(2**63)
        expect(Provider.new(min_64bit.to_s, "456").client_id_is_valid?).to be_truthy
      end

      it "is true for maximum 64-bit integer value" do
        max_64bit = (2**63) - 1
        expect(Provider.new(max_64bit.to_s, "456").client_id_is_valid?).to be_truthy
      end

      it "is false for values below minimum 64-bit integer" do
        below_min = -(2**63) - 1
        expect(Provider.new(below_min.to_s, "456").client_id_is_valid?).to be_falsey
      end

      it "is false for values above maximum 64-bit integer" do
        above_max = (2**63)
        expect(Provider.new(above_max.to_s, "456").client_id_is_valid?).to be_falsey
      end
    end

    describe "#has_valid_redirect?" do
      it "is true when the redirect url is the OOB uri" do
        provider = Provider.new("123", Provider::OAUTH2_OOB_URI)
        expect(provider.has_valid_redirect?).to be_truthy
      end

      it "is true when the redirect url is kosher for the developerKey" do
        stub_dev_key(double(redirect_domain_matches?: true))
        expect(provider.has_valid_redirect?).to be_truthy
      end

      it "is false otherwise" do
        stub_dev_key(double(redirect_domain_matches?: false))
        expect(provider.has_valid_redirect?).to be_falsey
      end
    end

    describe "#icon_url" do
      it "delegates to the key" do
        stub_dev_key(double(icon_url: "unique_url"))
        expect(provider.icon_url).to eq "unique_url"
      end
    end

    describe "#key" do
      it "is nil if there is no client id" do
        expect(Provider.new(nil).key).to be_nil
      end

      it "delegates to the class level finder on DeveloperKey" do
        key = double
        stub_dev_key(key)
        expect(provider.key).to eq key
      end
    end

    describe "authorized_token?" do
      let(:developer_key) { DeveloperKey.create! }
      let(:user) { User.create! }

      it "finds a pre existing token with the same scope" do
        user.access_tokens.create!(developer_key:, scopes: ["#{TokenScopes::OAUTH2_SCOPE_NAMESPACE}userinfo"], remember_access: true)
        expect(Provider.new(developer_key.id, "", ["userinfo"]).authorized_token?(user)).to be true
      end

      it "ignores tokens unless access is remembered" do
        user.access_tokens.create!(developer_key:, scopes: ["#{TokenScopes::OAUTH2_SCOPE_NAMESPACE}userinfo"])
        expect(Provider.new(developer_key.id, "", ["userinfo"]).authorized_token?(user)).to be false
      end

      it "ignores tokens for out of band requests" do
        user.access_tokens.create!(developer_key:, scopes: ["#{TokenScopes::OAUTH2_SCOPE_NAMESPACE}userinfo"], remember_access: true)
        expect(Provider.new(developer_key.id, Canvas::OAuth::Provider::OAUTH2_OOB_URI, ["userinfo"]).authorized_token?(user)).to be false
      end
    end

    describe "#app_name" do
      let(:key_attrs) { { name: "some app", user_name: "some user", email: "some email" } }
      let(:key) { double(key_attrs) }

      it "prefers the key name" do
        stub_dev_key(key)
        expect(provider.app_name).to eq "some app"
      end

      it "falls back to the user name" do
        key_attrs[:name] = nil
        stub_dev_key(key)
        expect(provider.app_name).to eq "some user"
      end

      it "falls back to the email if there is nothing else" do
        key_attrs[:name] = nil
        key_attrs[:user_name] = nil
        stub_dev_key(key)
        expect(provider.app_name).to eq "some email"
      end

      it "goes to the default app name if there are no pieces of data in the key" do
        key_attrs[:name] = nil
        key_attrs[:user_name] = nil
        key_attrs[:email] = nil
        stub_dev_key(key)
        expect(provider.app_name).to eq "Third-Party Application"
      end
    end

    describe "#session_hash" do
      before { stub_dev_key(double(id: 123)) }

      it "uses the key id for a client id" do
        expect(provider.session_hash[:client_id]).to eq "123"
      end

      it "passes the redirect_uri through" do
        provider = Provider.new("123", "some uri")
        expect(provider.session_hash[:redirect_uri]).to eq "some uri"
      end

      it "passes the scope through" do
        provider = Provider.new("123", "some uri", "userinfo,full_access")
        expect(provider.session_hash[:scopes]).to eq "userinfo,full_access"
      end
    end

    context "scopes" do
      let(:developer_key) { DeveloperKey.create! scopes: [TokenScopes::USER_INFO_SCOPE[:scope]] }
      let(:scopes) { [TokenScopes::USER_INFO_SCOPE[:scope]] }
      let(:provider) { Provider.new(developer_key.id, "some_uri", scopes) }

      describe "#valid_scopes?" do
        it "returns true if scopes requested are included on key" do
          expect(provider.valid_scopes?).to be(true)
        end

        context "with invalid scopes" do
          let(:scopes) { [TokenScopes::USER_INFO_SCOPE[:scope], "otherscope"] }

          it "returns false" do
            expect(provider.valid_scopes?).to be(false)
          end
        end
      end

      describe "#missing_scopes" do
        it "returns empty array if no scopes are missing" do
          expect(provider.missing_scopes).to eq([])
        end

        context "with missing scopes" do
          let(:scopes) { ["second", "third"] }

          it "lists missing scopes in array" do
            expect(provider.missing_scopes).to eq(["second", "third"])
          end
        end
      end
    end
  end
end
