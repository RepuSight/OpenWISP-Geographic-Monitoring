require 'test_helper'

class GroupsControllerTest < ActionController::TestCase
  test "unauthenticated user cannot get index" do
    get :index
    assert_redirected_to new_user_session_url
  end
  
  test "group index permissions" do
    sign_in users(:sfigato)
    get :index
    assert_response :forbidden, 'sfigato should not get group index'
    sign_out users(:sfigato)
    
    sign_in users(:brescia_admin)
    get :index
    assert_response :success, 'brescia_admin should get group index'
    assert_select "table#group_list tbody" do
      assert_select "tr", 3, "brescia_admin should see only 3 records"
    end
    
    sign_out users(:brescia_admin)
    sign_in users(:mixed_operator)
    get :index
    assert_response :success, 'mixed_operator should get group index'
    assert_select "table#group_list tbody" do
      assert_select "tr", 5, "mixed_operator should only 5 records"
    end
  end
    
  test "should get index" do
    sign_in users(:admin)
    get :index
    assert_response :success
    assert_select "table#group_list tbody" do
      assert_select "tr", Group.all.count
    end
  end
  
  test "should get new" do
    sign_in users(:admin)
    get :new
    assert_response :success
    assert_select "#group_form", 1
  end
  
  test "can create user" do
    sign_in users(:admin)
    group_count = Group.count
    # crete new user with 6 roles assigned
    post :create, :group => {
      :name => 'test general group',
      :description => 'test description yeah'
    }
    assert Group.count == group_count + 1, 'group count should have incremented of 1'
    new_group = Group.last
    assert new_group.name == 'test general group', 'name not been set as expected'
    assert new_group.description == 'test description yeah', 'description has not been set as expected'
    assert_redirected_to groups_path, 'should redirect to group list after success'
  end
  
  test "should get edit group" do
    sign_in users(:admin)
    get :edit, { :id => 1 }
    assert_response :success
    assert_select "#group_form", 1
  end
  
  test "should destroy group" do
    sign_in users(:admin)
    group_count = Group.count
    delete :destroy, { :id => 2 }
    assert_redirected_to groups_path, 'should redirect to group list after success'
    assert Group.count == group_count - 1
  end
  
  test "should not find delete button for default group" do
    sign_in users(:admin)
    get :index
    assert_response :success
    assert_select "#group_list tbody tr:first-child td:last-child", ""
  end
  
  test "should not destroy group 1" do
    sign_in users(:admin)
    group_count = Group.count
    delete :destroy, { :id => 1 }
    assert Group.count == group_count
    default_group = Group.find(1)
    assert !default_group.nil?
  end
end