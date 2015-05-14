class AdminController < ApplicationController

  layout 'admin'

  before_filter :authenticate_user!
  before_filter :verify_admin
  before_filter :fetch_counts, :only => ['dashboard','tickets','ticket', 'update_ticket', 'topic_search', 'user_profile']
  before_filter :pipeline, :only => ['tickets', 'ticket', 'topic_search', 'update_ticket']
  before_filter :remote_search, :only => ['tickets', 'ticket', 'topic_search', 'update_ticket']

  def dashboard
    #@users = PgSearch.multisearch(params[:q]).page params[:page]
    @topics = Topic.mine(current_user.id).pending.page params[:page]
  end

  def knowledgebase
    @categories = Category.featured.alpha
    @nonfeatured = Category.where(front_page: false).alpha

    respond_to do |format|
      format.html { render :action => "knowledgebase" }
    end
  end

  def articles
    @category = Category.where(id: params[:category_id]).first
    @docs = @category.docs.ordered.alpha

    respond_to do |format|
      format.html
      format.xml  { render :xml => @category }
    end
  end

  def tickets

    if params[:status].nil?
      @status = "pending"
    else
      @status = params[:status]
    end

    case @status

    when 'all'
      @topics = Topic.all.page params[:page]
    when 'new'
      @topics = Topic.unread.page params[:page]
    when 'active'
      @topics = Topic.active.page params[:page]
    when 'unread'
      @topics = Topic.unread.all.page params[:page]
    when 'assigned'
      @topics = Topic.mine(current_user.id).page params[:page]
    when 'pending'
      @topics = Topic.pending.mine(current_user.id).page params[:page]
    else
      @topics = Topic.where(current_status: @status).page params[:page]
    end


    @replies = Doc.replies
    @tracker.event(category: "Admin-Nav", action: "Click", label: @status.titleize)

    respond_to do |format|
      format.html
      format.js
    end

  end

  # view ticket
  def ticket

    @topic = Topic.where(id: params[:id]).first

    if @topic.current_status == 'new'
      @tracker.event(category: "Agent: #{current_user.name}", action: "Opened Ticket", label: @topic.to_param, value: @topic.id)
      @topic.current_status = 'open'
      @topic.save
    end

    @posts = @topic.posts

    @tracker.event(category: "Agent: #{current_user.name}", action: "Viewed Ticket", label: @topic.to_param, value: @topic.id)

    fetch_counts
    respond_to do |format|
      format.html
      format.js
    end


  end

  def new_ticket
    @topic = Topic.new
    @user = User.new

    respond_to do |format|
      format.js
    end
  end

  def create_ticket

    @page_title = t(:start_discussion, default: "Start a New Discussion")
    @title_tag = "#{Settings.site_name}: #{@page_title}"

    @forum = Forum.find(1)
    @user = User.where(email: params[:topic][:user][:email]).first

    @topic = @forum.topics.new(
      name: params[:topic][:name],
      private: true )

    if @user.nil?

      @user = @topic.build_user

      # generate user password
      source_characters = "0124356789abcdefghijk"
      password = ""
      1.upto(8) { password += source_characters[rand(source_characters.length),1] }

      @user.name = params[:topic][:user][:name]
      @user.login = params[:topic][:user][:email].split("@")[0]
      @user.email = params[:topic][:user][:email]
      @user.password = password

    else
      @topic.user_id = @user.id
    end

    respond_to do |format|

      if (@user.save || !@user.nil?) && @topic.save

        @post = @topic.posts.create(:body => params[:post][:body], :user_id => @user.id, :kind => 'first')

        # Send email
        UserMailer.new_user(@user).deliver #if Settings.send_email == true

        # track event in GA
        @tracker.event(category: 'Request', action: 'Post', label: 'New Topic')
        @tracker.event(category: 'Agent: Unassigned', action: 'New', label: @topic.to_param)

        format.js {
          @topics = Topic.recent.page params[:page]
          render action: 'tickets'
        }
      else
        format.html {
          render action: 'new_ticket'
        }
      end
    end
  end

  # simple search tickets by # and user
  def topic_search

    # search for user, if [one] found, we'll give details on that person
    # if more than one found, we'll list them
    users = User.user_search(params[:q])

    if users.size == 0 # not a user search, so look for topics
      @topics = Topic.admin_search(params[:q]).page params[:page]
      template = 'tickets'
    else
      if users.size == 1
        @user = users.first
        @topics = Topic.admin_search(params[:q]).page params[:page]
        @topic = Topic.where(user_id: @user.id).first unless @user.nil?
        template = 'tickets'
      else
        @users = users.page params[:page]
        template = 'users'
      end
    end

    respond_to do |format|
      format.html {
        render template
      }
      format.js {
        render template
      }
    end

  end

  # show user profile and tickets
  def user_profile

    @user = User.where(id: params[:id]).first
    @topics = Topic.where(user_id: @user.id).page params[:page]

    # We still have to grab the first topic for the user to use the same user partial
    @topic = Topic.where(user_id: @user.id).first

    respond_to do |format|
      format.html {
        render 'tickets'
      }
      format.js {
        render 'tickets'
      }
    end


  end

  # Updates discussion status
  def update_ticket

    #handle array of topics
    params[:topic_ids].each do |id|

      @topic = Topic.where(id: id).first
      @minutes = 0

      # actions for each status change
      unless params[:change_status].blank?
        case params[:change_status]
        when 'closed'
          @topic.current_status = "closed"
          message = "This ticket has been closed by the support staff."
        when 'reopen'
          @topic.current_status = "open"
          message = "This ticket has been reopened by the support staff."
        else
          @topic.current_status = params[:change_status] unless params[:change_status].blank?
        end
        @action_performed = "Marked #{params[:change_status].titleize}"
      end

      @topic.save

      # Calls to GA for close, reopen, assigned
      @tracker.event(category: "Agent: #{current_user.name}", action: @action_performed, label: @topic.to_param, value: @minutes)

      #Add post indicating status change
      @topic.posts.create(user_id: current_user.id, body: message, kind: "reply") unless message.nil?

    end
    @posts = @topic.posts

    fetch_counts
    respond_to do |format|
      format.js {
        if params[:topic_ids].count > 1
          get_tickets
          render 'tickets'
        else
          render 'update_ticket', id: @topic.id
        end
      }
    end

  end

  # Assigns a discussion to another agent
  def assign_agent

    @count = 0
    #handle array of topics
    params[:topic_ids].each do |id|

      @topic = Topic.where(id: id).first

      @minutes = 0

      unless params[:assigned_user_id].blank?

        # if message was unassigned previously, use the new assignee
        # this is to give note attribution below
        previous_assigned_id = @topic.assigned_user_id? ? @topic.assigned_user_id : params[:assigned_user_id]

        @topic.assigned_user_id = params[:assigned_user_id]
        @topic.current_status = 'pending'
        @topic.save

        # Create internal note
        assigned_user = User.find(params[:assigned_user_id])
        @topic.posts.create(user_id: previous_assigned_id, body: "Discussion has been transferred to #{assigned_user.name}.", kind: "note")

        @action_performed = "Assigned to #{assigned_user.name.titleize}"

        # Calls to GA
        @tracker.event(category: "Agent: #{current_user.name}", action: @action_performed, label: @topic.to_param, value: @minutes)

      end
      @count = @count + 1
    end

    if params[:topic_ids].count > 1
      get_tickets
    else
      @posts = @topic.posts
    end

    logger.info("Count: #{params[:topic_ids].count}")

    fetch_counts
    respond_to do |format|
      format.html #render action: 'ticket', id: @topic.id
      format.js {
        if params[:topic_ids].count > 1
          get_tickets
          render 'tickets'
        else
          render 'update_ticket', id: @topic.id
        end
      }
    end


  end

  # Toggle privacy of a topic
  def toggle_privacy

    #handle array of topics
    params[:topic_ids].each do |id|

      @topic = Topic.where(id: id).first
      @topic.private = params[:private]
      @topic.forum_id = params[:forum_id]
      @topic.save


    end
    @posts = @topic.posts

    fetch_counts
    respond_to do |format|
      format.js {
        if params[:topics_ids].count > 1
          render 'tickets'
        else
          render 'update_ticket', id: @topic.id
        end
      }
    end

  end

  # "Toggles" post visibility by marking it inactive
  def toggle_post

    @post = Post.find(params[:id])
    @topic = @post.topic

    @post.active = params[:active]
    @post.save

    respond_to do |format|
      format.html
      format.js
    end

  end

  def communities
    @forums = Forum.where(private: false).order('name ASC')
  end

  def users
    @users = User.all.page params[:page]
    @user = User.new
  end

  def user
    @user = User.where(id: params[:id]).first
  end

  def user_search
    @users = User.user_search(params[:q]).page params[:page]

    respond_to do |format|
      format.js
      format.html {
        render admin_users_path
      }
    end

  end

  private

  def pipeline
    @pipeline = true
  end

  def remote_search
    @remote_search = true
  end

  def get_tickets
    if params[:status].nil?
      @status = "pending"
    else
      @status = params[:status]
    end

    case @status

    when 'all'
      @topics = Topic.all.page params[:page]
    when 'new'
      @topics = Topic.unread.page params[:page]
    when 'active'
      @topics = Topic.active.page params[:page]
    when 'unread'
      @topics = Topic.unread.all.page params[:page]
    when 'assigned'
      @topics = Topic.mine(current_user.id).page params[:page]
    when 'pending'
      @topics = Topic.pending.mine(current_user.id).page params[:page]
    else
      @topics = Topic.where(current_status: @status).page params[:page]
    end
  end

end
