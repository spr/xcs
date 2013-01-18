require 'thor'
require 'appscript'
require 'pathname'

class XcodeProxy
  def initialize (path)
    @project = nil
    @project_document = File.basename(path)
    full_path = Pathname.new(path).realpath.to_s
    mac_path = full_path
    mac_path.sub!(/^\//, '')
    mac_path.gsub!(/\//, ':')
    @app = Appscript.app('Xcode')
    @version = @app.version.get.split('.')[0].to_i
    @app.open(mac_path)
    prjs = @app.projects.get
    prjs.each do |pr|
      tmp_path = pr.path.get
      if path == tmp_path then
        @project = pr.name.get
      end
    end
    if @project == nil then
      puts "Failed to open project"
      puts "Project path: #{path}"
      puts "XCode projects' pathes:"
      prjs.each do |pr|
        tmp_path = pr.path.get
        puts "  #{tmp_path}"
      end
      exit(1)
    end
  end

  def close
    # close does not work for Xcode4
    if @version == 3 then
        @app.project_documents[@project_document].close
    end
  end

  def list(group = nil, verbose = false)
    if group == nil then
      root_group = @app.projects[@project].root_group
      list_group(root_group, verbose)
    else
      root_group = @app.projects[@project].root_group
      group_ref = find_group_by_path(root_group, group)
      list_group(group_ref, verbose) if group != nil
    end
  end

  def add(path, group)
    root_group = @app.projects[@project].root_group
    group_ref = find_group_by_path(root_group, group)
    p group_ref
    if group_ref != nil then
      file = File.basename(path)
      file_ref = group_ref.make(
        :new => :Xcode_3_file_reference,
        :with_properties => {
          :name => file,
          :full_path => path
        })

      if file_ref != nil then
        compilable = %w[.cpp .c .C .m .mm]
        compilable.each do |ext|
          if path =~ /#{ext}$/ then
            # file_ref.add(:to => @app.projects[@project].targets[1])
            break
          end
        end
      end
    end
  end

  def remove(path)
    filename = File.basename(path)
    group = File.dirname(path)
    root_group = @app.projects[@project].root_group
    group_ref = find_group_by_path(root_group, group)
    return if group_ref == nil

    if @version == 4 then 
        file_refs = group_ref.Xcode_3_file_references.get
    else
        file_refs = group_ref.file_references.get
    end
    file_refs.each do |fref|
      fn = fref.name.get
      if fn == filename then 
        id = fref.id_.get
        if @version == 4 then 
            p group_ref.Xcode_3_file_references.ID(id).path.get
            group_ref.delete(group_ref.Xcode_3_file_references.ID(id))
        else
            group_ref.delete(group_ref.file_references.ID(id))
        end
      end
    end
  end

  def mkgroup(group)
    @app.projects[@project].root_group.make(
      :new => :Xcode_3_group, 
      :with_properties => {:name => group}
    )
  end

  def rmgroup(group)
    root_group = @app.projects[@project].root_group
    group_ref = find_group_by_path(root_group, group)
    if group_ref == nil then
      puts "Group #{group} not found"
      return
    end
    content = group_ref.item_references.get
    if content.count > 0 then
      puts "Group #{group} is not empty"
      return
    end
    id = group_ref.id_.get
    root_group.delete(root_group.Xcode_3_groups.ID(id))
  end

private

  def print_groupref(group_ref, verbose, indent = 0)
    name = group_ref.name.get
    id = group_ref.id_.get
    text = "#{name}"
    text += "(#{id})" if (verbose)
    print "  " * indent
    puts "#{text}/"
  end

  def print_fileref(file_ref, verbose, indent = 0)
    name = file_ref.name.get
    id = file_ref.id_.get
    path = file_ref.full_path.get
    text = "#{name}"
    text += "(#{id}, #{path})" if (verbose)
    print "  " * indent
    puts "#{text}"
  end

  def list_group(group_ref, verbose, indent = 0)
    print_groupref(group_ref, verbose, indent)
    items = group_ref.item_references.get
    items.each do |item| 
      item_class = item.class_.get
      if (item_class == :group) || (item_class == :Xcode_3_group) then
        list_group(item, verbose, indent + 1)
      elsif (item_class == :file_reference) || 
          (item_class == :Xcode_3_file_reference) then
        print_fileref(item, verbose, indent + 1)
      else
        print "  " * (indent+1)
        puts "ERROR: Unknown item class: #{item_class}"
      end
    end
  end

  def find_group_by_path(base_group_ref, path)
    sub_groups = path.split("/")
    current_group_ref = base_group_ref
    sub_groups.each do |group_to_find|
      items = current_group_ref.item_references.get
      items.each do |item|
        item_class = item.class_.get
        if (item_class == :group) || (item_class == :Xcode_3_group) then
          if item.name.get == group_to_find then
            current_group_ref = item
            break
          end
        end
      end
      if current_group_ref.name.get != group_to_find then
        puts "ERROR: Could not find group: #{group_to_find}"
        return nil
      end
    end

    return current_group_ref

  end

end

class Xcs < Thor

  def initialize(*args)
    super
    @proxy = nil
  end

  method_options :verbose => :boolean
  desc 'list [Group] [--verbose]',  'List project contents'
  def list(group = nil)
    open_project
    @proxy.list(group, options.verbose?)
  end

  desc 'add File [Group]',  'Add file to a group. By default adds to "Source"'
  def add(path, group)
    open_project
    @proxy.add(File.expand_path(path), group)
    @proxy.close 
  end

  desc 'rm Group/File',  'Remove file reference from a project'
  def rm(path)
    open_project
    @proxy.remove(path)
    @proxy.close 
  end

  desc 'mkgroup Group',  'Create new subgroup in root group'
  def mkgroup(group)
    open_project
    @proxy.mkgroup(group)
    @proxy.close 
  end

  desc 'rmgroup Group',  'Remove Group'
  def rmgroup(group)
    open_project
    @proxy.rmgroup(group)
    @proxy.close 
  end

  no_tasks { 
    def open_project
      # try to find .xcodeproj file
      cwd = Pathname.new(Dir.pwd)
      project_path = nil
      while true do
        projects = Dir.entries(cwd).grep /.xcodeproj$/
        if projects.count > 1 then
          puts "Confused: more then one .xcodeproj file found"
          exit(1)
        end
        if projects.count == 1 then
          proj_path = (cwd + projects[0]).realpath.to_s
          puts "Using #{proj_path}"

          break
        end
        break if cwd == cwd.parent
        cwd = cwd.parent
      end
      if proj_path == nil then
        puts "No .xcodeproj file found, giving up"
        exit(1)
      end
      @proxy = XcodeProxy.new(proj_path)
    end
  }
end
