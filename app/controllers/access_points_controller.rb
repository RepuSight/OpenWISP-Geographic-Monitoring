# This file is part of the OpenWISP Geographic Monitoring
#
# Copyright (C) 2012 OpenWISP.org
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class AccessPointsController < ApplicationController
  before_filter :authenticate_user!, :load_wisp, :wisp_breadcrumb
  
  skip_before_filter :verify_authenticity_token, :only => [:change_group, :toggle_public, :batch_change_group, :erase_favourite]

  access_control do
    default :deny

    actions :index, :show, :change_group, :select_group, :toggle_public, :batch_change_group, :batch_select_group, :favourite, :erase_favourite do
      allow :wisps_viewer
      allow :wisp_access_points_viewer, :of => :wisp, :if => :wisp_loaded?
    end
    
    actions :batch_change_group do
      allow :wisps_viewer
      allow :wisp_access_points_viewer
    end
  end

  def index
    @showmap = CONFIG['showmap']
    @access_point_pagination = CONFIG['access_point_pagination']
    
    # if group view
    if params[:group_id]
      begin
        @group = Group.select([:id, :name, :monitor, :up, :down, :unknown, :total]).where(['wisp_id IS NULL or wisp_id = ?', @wisp.id]).find(params[:group_id])  
      rescue ActiveRecord::RecordNotFound
        render :file => "#{Rails.root}/public/404.html", :status => 404, :layout => false
        return
      end
    end
    
    respond_to do |format|
      format.any(:html, :js) { @access_points = access_points_with_sort_search_and_paginate.of_wisp(@wisp) }
      format.json { @access_points = access_points_with_filter.of_wisp(@wisp).draw_map }
      format.rss { @access_points = AccessPoint.of_wisp(@wisp).on_georss }
    end

    crumb_for_group
    crumb_for_wisp
    crumb_for_access_point_favourite
  end

  def show
    @access_point = AccessPoint.with_properties_and_group.find(params[:id])
    @access_point.build_property_set_if_group_name_empty()

    crumb_for_wisp
    crumb_for_access_point
  end
  
  def select_group
    @access_point_id = params[:access_point_id]
    @groups = Group.all_join_wisp("wisp_id = ? OR wisp_id IS NULL", [@wisp.id])
    render :layout => false
  end
  
  def change_group
    # ensure AP and Group are correct otherwise return 404
    begin
      ap = AccessPoint.find(params[:access_point_id])
      # ensure group is a general group of specific of this wisp
      group = Group.select([:id, :name]).where(['wisp_id IS NULL or wisp_id = ?', @wisp.id]).find(params[:group_id])
    rescue ActiveRecord::RecordNotFound
      render :status => 404, :nothing => true
      return
    end
    # get or create property set
    property_set = ap.properties
    # change gorup, save and return json response
    property_set.group_id = group.id
    property_set.save!
    # update group counts (total, up, down, unknown)
    Group.update_all_counts()
    respond_to do |format|
      format.json { render :json => group.attributes }
    end
  end
  
  def batch_select_group
    if wisp_loaded?
      @groups = Group.all_join_wisp("wisp_id = ? OR wisp_id IS NULL", [@wisp.id])
    else
      # maybe is too much! - for the moment it works so let's keep it
      if current_user.has_role?(:wisps_viewer)
        @groups = Group.all_join_wisp()
      else
        @groups = Group.all_accessible_to(current_user)
      end
    end    
    render :template => 'access_points/select_group', :layout => false
  end
  
  def batch_change_group
    # parameters expected:
    # * group_id (int)
    # * access_points (array)
    group_id = params[:group_id]
    access_points_id = params[:access_points]
    
    # ensure all parameters are sent correctly otherwise return 400 bad request status code
    if group_id.nil? or group_id == '' or access_points_id.nil? or access_points_id.length < 1# or group_id.class != Fixnum or access_points_id.class != Array
      render :status => 400, :json => { "details" => I18n.t(:Bad_format_parameters) }
      return
    end
    
    # ensure Group is correct otherwise return 404
    begin
      # ensure group is a general group of specific of this wisp
      group = Group.select([:id, :name, :wisp_id]).find(group_id)
    rescue ActiveRecord::RecordNotFound
      render :status => 404, :json => { "details" => I18n.t(:Group_not_found) }
      return
    end
    
    # get an array of id for which the user is authorized
    authorized_for_wisps = current_user.roles_search(:wisp_access_points_viewer).map { |r| r.authorizable_id }
    
    # in case user the array is empty, the user is wisps_viewer, because even if he is not wisp_access_points_viewer for any wisp
    # he was able to get here (otherwise he would have been blocked before because the acl rules on top)
    wisps_viewer = authorized_for_wisps.length < 1 ? true : false
    
    # if moving access points to a group of a specific wisp, user must be authorized for that wisp
    if not group.wisp_id.nil? and not wisps_viewer and not authorized_for_wisps.include?(group.wisp_id)
      render :status => 403, :json => { "details" => I18n.t(:User_does_not_have_permission) }
      return
    end
    
    access_points = AccessPoint.with_properties.find(access_points_id)
    
    # check permissions first
    access_points.each do |ap|
      # user must be authorized for wisp_id of the access point he wants to edit
      if not wisps_viewer and not authorized_for_wisps.include?(ap.wisp_id)
        render :status => 403, :json => { "details" => I18n.t(:User_does_not_have_permission_ap_id, :ap_id => ap.id) }
        return
      end
      
      # wisp_id of access point must coincide with wisp_id of group (unless wisp_id of group is NULL)
      if not group.wisp_id.nil? and not ap.wisp_id == group.wisp_id
        render :status => 403, :json => { "details" => I18n.t(:Moving_access_point_different_wisp_not_allowed, :wisp1 => ap.wisp.name, :wisp2 => group.wisp.name) }
        return
      end
      
      # ensure ap has property_sets related object
      if ap.group_id.nil?
        # create properties!
        ap.properties.save!
      end
    end
    
    AccessPoint.batch_change_group(access_points, group.id)
    
    # update group counts
    Group.update_all_counts()
    
    render :status => 200, :json => { "details" => I18n.t(:Access_point_updated, :length => access_points.length) }
  end
  
  # toggle published AP in the GeoRSS xml
  def toggle_public
    ap = PropertySet.find_by_access_point_id(params[:id])
    ap.public = !ap.public
    ap.save!
    respond_to do |format|
      format.json{
        image = view_context.image_path(ap.public ? 'accept.png' : 'delete.png')
        render :json => { 'public' => ap.public, 'image' => image }
      }
    end
  end

  def favourite
    @showmap = CONFIG['showmap']
    @access_point_pagination = CONFIG['access_point_pagination']
    
    @favourite_page = true
    
    respond_to do |format|
      format.any(:html, :js) {
        @access_points = access_points_with_sort_search_and_paginate(true).of_wisp(@wisp)
        render :index
      }
      format.json {
        @access_points = access_points_with_filter.of_wisp(@wisp).draw_map
        render :index
      }
      format.rss {
        @access_points = AccessPoint.with_properties.of_wisp(@wisp).on_georss
        render :index
      }
    end
    
    crumb_for_wisp
    crumb_for_access_point_favourite
  end

  def erase_favourite
    @access_points = AccessPoint.with_properties.where(:wisp_id => @wisp.id)
    
    @access_points.each do |ap|
      if ap.favourite?
        ap.property_set.update_attributes(:favourite => '0' )
      end
    end
    
    respond_to do |format|
      format.html {
        redirect_to wisp_access_point_favourite_path(@wisp)
      }
      format.js {
        render :nothing => true
      }
    end
  end

  private

  def access_points_with_filter
    access_points = AccessPoint.with_properties_and_group.scoped
    
    if params[:group_id]
      access_points = access_points.where(:wisp_id => @wisp.id, 'property_sets.group_id' => params[:group_id])
    end
    
    case params[:filter]
      when 'up'
        access_points.up
      when 'down'
        access_points.down
      when 'unknown'
        access_points.unknown
      else
        access_points
    end
  end

  def access_points_with_sort_search_and_paginate(fav=nil)
    query = params[:q] || nil
    column = params[:column] ? params[:column].downcase : nil
    direction = %w{asc desc}.include?(params[:order]) ? params[:order] : 'asc'

    # model delegation caused too many queries, used a workaround in the specific model method
    access_points = AccessPoint.with_properties_and_group.scoped
    
    if params[:group_id]
      access_points = access_points.where(:wisp_id => @wisp.id, 'property_sets.group_id' => params[:group_id])
    end
    
    access_points = access_points.sort_with(t_column(column), direction) if column
    access_points = access_points.quicksearch(query) if query
    
    access_points = access_points.quickfavourite(fav) if fav
   
    per_page = params[:per]
    access_points.page(params[:page]).per(per_page)
  end

  def t_column(column)
    i18n_columns = {}
    i18n_columns[I18n.t(:status, :scope => [:activerecord, :attributes, :access_point])] = 'status'
    i18n_columns[I18n.t(:public, :scope => [:activerecord, :attributes, :access_point])] = 'public'
    i18n_columns[I18n.t(:site_description, :scope => [:activerecord, :attributes, :access_point])] = 'site_description'
    i18n_columns[I18n.t(:favourite, :scope => [:activerecord, :attributes, :access_point])] = 'favourite'

    AccessPoint.column_names.each do |col|
      i18n_columns[I18n.t(col, :scope => [:activerecord, :attributes, :access_point])] = col
    end

    i18n_columns.include?(column) ? i18n_columns[column] : 'hostname'
  end
  
  def crumb_for_wisp
    begin
      if params[:group_id]
        add_breadcrumb I18n.t(:Access_points_for_group, :group => @group.name), wisp_group_access_points_path(@wisp, @group)
      else
        add_breadcrumb I18n.t(:Access_points_for, :wisp => @wisp.name), wisp_access_points_path(@wisp)
      end
    rescue
      add_breadcrumb I18n.t(:Access_points_of_every_wisp), access_points_path
    end
  end
  
  def crumb_for_access_point_favourite
    #add_breadcrumb I18n.t(:Accesspoint_favourite), wisp_access_point_favourite_path(@wisp)
  end

  def crumb_for_access_point
    add_breadcrumb I18n.t(:Access_point_named, :hostname => @access_point.hostname), wisp_access_point_path(@access_point.wisp, @access_point)
  end
  
  def crumb_for_group
    if params[:group_id]
      add_breadcrumb(I18n.t(:Group_list_of_wisp, :wisp => @wisp.name), wisp_groups_path(@wisp))
    end
  end
end
