# frozen_string_literal: true

#
# Copyright (C) 2015 - present Instructure, Inc.
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

require_relative "../../helpers/gradebook_common"
require_relative "../../helpers/assignment_overrides"
require_relative "../pages/gradebook_page"

# NOTE: We are aware that we're duplicating some unnecessary testcases, but this was the
# easiest way to review, and will be the easiest to remove after the feature flag is
# permanently removed. Testing both flag states is necessary during the transition phase.
shared_examples "Gradebook - arrange by due date" do |ff_enabled|
  include_context "in-process server selenium tests"
  include AssignmentOverridesSeleniumHelper
  include GradebookCommon

  before :once do
    # Set feature flag state for the test run - this affects how the gradebook data is fetched, not the data setup
    if ff_enabled
      Account.site_admin.enable_feature!(:performance_improvements_for_gradebook)
    else
      Account.site_admin.disable_feature!(:performance_improvements_for_gradebook)
    end
    gradebook_data_setup
    @assignment = @course.assignments.first
  end

  before do
    user_session(@teacher)
    Gradebook.visit(@course)
  end

  it "validates arrange columns by due date option", priority: "1" do
    expected_text = "–"

    Gradebook.open_view_menu_and_arrange_by_menu
    Gradebook.view_arrange_by_submenu_item("Due Date - Oldest to Newest").click
    first_row_cells = find_slick_cells(0, f("#gradebook_grid .container_1"))

    expect(first_row_cells[0]).to include_text expected_text

    driver.action.send_keys(:escape).perform
    Gradebook.open_view_menu_and_arrange_by_menu

    expect(Gradebook.popover_menu_item_checked?("Due Date - Oldest to Newest")).to eq "true"

    # Setting should stick after reload
    Gradebook.visit(@course)
    first_row_cells = find_slick_cells(0, f("#gradebook_grid .container_1"))
    expect(first_row_cells[0]).to include_text expected_text

    first_row_cells = find_slick_cells(0, f("#gradebook_grid .container_1"))
    expect(first_row_cells[0]).to include_text expected_text
    expect(first_row_cells[1]).to include_text @assignment_1_points
    expect(first_row_cells[2]).to include_text @assignment_2_points

    Gradebook.open_view_menu_and_arrange_by_menu

    expect(Gradebook.popover_menu_item_checked?("Due Date - Oldest to Newest")).to eq "true"
  end

  it "puts assignments with no due date last when sorting by due date and VDD", priority: "2" do
    assignment2 = @course.assignments.where(title: "second assignment").first
    assignment3 = @course.assignments.where(title: "assignment three").first
    # create 1 section
    @section_a = @course.course_sections.create!(name: "Section A")
    # give second assignment a default due date and an override
    assignment2.update!(due_at: 3.days.from_now)
    create_assignment_override(assignment2, @section_a, 2)

    Gradebook.open_view_menu_and_arrange_by_menu
    Gradebook.view_arrange_by_submenu_item("Due Date - Oldest to Newest").click

    # since due date changes in assignments don't reflect in column sorting without a refresh
    Gradebook.visit(@course)
    expect(f("#gradebook_grid .container_1 .slick-header-column:nth-child(1)")).to include_text(assignment3.title)
    expect(f("#gradebook_grid .container_1 .slick-header-column:nth-child(2)")).to include_text(assignment2.title)
    expect(f("#gradebook_grid .container_1 .slick-header-column:nth-child(3)")).to include_text(@assignment.title)
  end

  it "arranges columns by due date when multiple due dates are present", priority: "2" do
    assignment3 = @course.assignments.where(title: "assignment three").first
    # create 2 sections
    @section_a = @course.course_sections.create!(name: "Section A")
    @section_b = @course.course_sections.create!(name: "Section B")
    # give each assignment a default due date
    @assignment.update!(due_at: 3.days.from_now)
    assignment3.update!(due_at: 2.days.from_now)
    # creating overrides in each section
    create_assignment_override(@assignment, @section_a, 5)
    create_assignment_override(assignment3, @section_b, 4)

    Gradebook.open_view_menu_and_arrange_by_menu
    Gradebook.view_arrange_by_submenu_item("Due Date - Oldest to Newest").click

    expect(f("#gradebook_grid .container_1 .slick-header-column:nth-child(1)")).to include_text(assignment3.title)
    expect(f("#gradebook_grid .container_1 .slick-header-column:nth-child(2)")).to include_text(@assignment.title)
  end
end

describe "Gradebook - arrange by due date" do
  it_behaves_like "Gradebook - arrange by due date", true
  it_behaves_like "Gradebook - arrange by due date", false
end
