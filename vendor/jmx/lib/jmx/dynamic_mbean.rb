module JMX
  import javax.management.MBeanParameterInfo
  import javax.management.MBeanOperationInfo
  import javax.management.MBeanAttributeInfo
  import javax.management.MBeanInfo

  # Module that is used to bridge java to ruby and ruby to java types.
  module JavaTypeAware
    # Current list of types we understand  If it's not in this list we are 
    # assuming that we are going to convert to a java.object
    SIMPLE_TYPES = {
      :int => ['java.lang.Integer', lambda {|param| param.to_i}],
      :list => ['java.util.List', lambda {|param| param.to_a}],
      :long => ['java.lang.Long', lambda {|param| param.to_i}],
      :float => ['java.lang.Float', lambda {|param| param.to_f}],
      :map => ['java.util.Map', lambda {|param| param}],
      :set => ['java.util.Set', lambda {|param| param}],
      :string => ['java.lang.String', lambda {|param| "'#{param.to_s}'"}],
      :void => ['java.lang.Void', lambda {|param| nil}]
    }

    def to_java_type(type_name)
      SIMPLE_TYPES[type_name][0] || type_name
    end
    #TODO: I'm not sure this is strictly needed, but funky things can happen if you 
    # are expecting your attributes (from the ruby side) to be ruby types and they are java types.
    def to_ruby(type_name)
      SIMPLE_TYPES[type_name][1] || lambda {|param| param}
    end
  end

  class Parameter
    include JavaTypeAware 

    def initialize(type, name, description)
      @type, @name, @description = type, name, description
    end

    def to_jmx
      MBeanParameterInfo.new @name.to_s, to_java_type(@type), @description
    end
  end

  class Operation < Struct.new(:description, :parameters, :return_type, :name, :impact)
    include JavaTypeAware

    def initialize(description)
      super
      self.parameters, self.impact, self.description = [], MBeanOperationInfo::UNKNOWN, description
    end

    def to_jmx
      java_parameters = parameters.map { |parameter| parameter.to_jmx }
      MBeanOperationInfo.new name.to_s, description, java_parameters.to_java(javax.management.MBeanParameterInfo), to_java_type(return_type), impact
    end
  end    
  
  class Attribute < Struct.new(:name, :type, :description, :is_reader, :is_writer, :is_iser)
    include JavaTypeAware
    
    def initialize(name, type, description, is_rdr, is_wrtr)
      super
      self.description, self.type, self.name = description, type, name
      self.is_reader,self.is_writer, self.is_iser = is_rdr, is_wrtr, false
    end

    def to_jmx
      MBeanAttributeInfo.new(name.to_s, to_java_type(type), description, is_reader, is_writer, is_iser) 
    end
  end
end

#  The Ruby-Java JMX utilities work throughout the DynamicMBean concept.  Creators of Ruby based MBeans must inherit this
# class (<tt>RubyDynamicMBean</tt>) in their own bean classes and then register them with a JMX mbean server.  
#  Here is an example:
#       class MyMBean < RuybDynamicMBean
#         rw_attribute :status, :string, "Status information for this process"
#         
#         operation "Shutdown this process"
#         parameter :string, "user_name", "Name of user requesting shutdown"
#         returns :string
#         def shutdown(user_name)
#            "shutdown requests more time"
#         end
#       end
# Once you have defined your bean class you can start declaring attributes and operations.  
# Attributes come in three flavors: read, write, and read write.  Simmilar to the <tt>attr*</tt>
# helpers, there are helpers that are used to create management attributes. Use +r_attribute+,
# +w_attribute+, and +rw_attribute+ to declare attributes, and the +operation+, +returns+, 
# and +parameter+ helpers to define a management operation.
# Creating attributes with the *_attribute convention ALSO creates ruby accessors 
# (it invokes the attr_accessor/attr_reader/attr_writer ruby helpers) to create ruby methods 
# like: user_name= and username.  So in your ruby code you can treat the attributes 
# as "regular" ruby accessors
class RubyDynamicMBean
  import javax.management.MBeanOperationInfo
  import javax.management.MBeanAttributeInfo
  import javax.management.DynamicMBean
  import javax.management.MBeanInfo
  include JMX::JavaTypeAware
  
  #NOTE this will not be needed when JRuby-3164 is fixed.
  def self.inherited(cls)
    cls.send(:include, DynamicMBean)
  end
  
  # TODO: preserve any original method_added?
  # TODO: Error handling here when it all goes wrong?
  def self.method_added(name) #:nodoc:
    return if Thread.current[:op].nil?
    Thread.current[:op].name = name
    operations << Thread.current[:op].to_jmx
    Thread.current[:op] = nil
  end

  def self.attributes #:nodoc:
    Thread.current[:attrs] ||= []
  end
  
  def self.operations #:nodoc:
    Thread.current[:ops] ||= []
  end

  # the <tt>rw_attribute</tt> method is used to declare a JMX read write attribute.
  # see the +JavaSimpleTypes+ module for more information about acceptable types
  # usage: 
  # rw_attribute :attribute_name, :string, "Description displayed in a JMX console"
  #--methods used to create an attribute.  They are modeled on the attrib_accessor
  # patterns of creating getters and setters in ruby
  #++
  def self.rw_attribute(name, type, description)
    attributes << JMX::Attribute.new(name, type, description, true, true).to_jmx
    attr_accessor name    
    #create a "java" oriented accessor method
    define_method("jmx_get_#{name.to_s.downcase}") do 
      begin
        #attempt conversion
        java_type = to_java_type(type)
        value = eval "#{java_type}.new(@#{name.to_s})"
      rescue
        #otherwise turn it into a java Object type for now.  
        value = eval "Java.ruby_to_java(@#{name.to_s})"
      end
      attribute = javax.management.Attribute.new(name.to_s, value)
    end

    define_method("jmx_set_#{name.to_s.downcase}") do |value| 
      blck = to_ruby(type)
      eval "@#{name.to_s} = #{blck.call(value)}"
    end    
  end
  
  # the <tt>r_attribute</tt> method is used to declare a JMX read only attribute.
  # see the +JavaSimpleTypes+ module for more information about acceptable types
  # usage: 
  #  r_attribute :attribute_name, :string, "Description displayed in a JMX console"
  def self.r_attribute(name, type, description)
    attributes << JMX::Attribute.new(name, type, description, true, false).to_jmx
    attr_reader name
    #create a "java" oriented accessor method
    define_method("jmx_get_#{name.to_s.downcase}") do 
      begin
        #attempt conversion
        java_type = to_java_type(type)
        value = eval "#{java_type}.new(@#{name.to_s})"
      rescue
        #otherwise turn it into a java Object type for now.  
        value = eval "Java.ruby_to_java(@#{name.to_s})"
      end
      attribute = javax.management.Attribute.new(name.to_s, value)
    end
  end
  
  # the <tt>w_attribute</tt> method is used to declare a JMX write only attribute.
  # see the +JavaSimpleTypes+ module for more information about acceptable types
  # usage: 
  #  w_attribute :attribute_name, :string, "Description displayed in a JMX console"
  def self.w_attribute(name, type, description)
    attributes << JMX::Attribute.new(name, type, description, false, true).to_jmx
    attr_writer name
    define_method("jmx_set_#{name.to_s.downcase}") do |value|
      blck = to_ruby(type)
      eval "@#{name.to_s} = #{blck.call(value)}"
    end
  end

  # Use the operation method to declare the start of an operation
  # It takes as an argument the description for the operation
  #     operation "Used to start the service"
  #     def start
  #     end
  #--
  # Last operation wins if more than one
  #++
  def self.operation(description)

    # Wait to error check until method_added so we can know method name
    Thread.current[:op] = JMX::Operation.new description
  end

  # Used to declare a parameter (you can declare more than one in succession) that
  # is associated with the currently declared operation.
  #     operation "Used to update the name of a service"
  #     parameter :string, "name", "Set the new name of the service"
  #     def start
  #     end
  def self.parameter(type, name=nil, description=nil)
    Thread.current[:op].parameters << JMX::Parameter.new(type, name, description)
  end

  # Used to declare the return type of the operation
  #     operation "Used to update the name of a service"
  #     parameter :string, "name", "Set the new name of the service"
  #     returns :void
  #     def set_name
  #     end
  def self.returns(type)
    Thread.current[:op].return_type = type
  end
  
  # when creating a dynamic MBean we need to provide it with a 
  # name and a description.
  def initialize(name, description)
    operations = self.class.operations.to_java(MBeanOperationInfo)
    attributes = self.class.attributes.to_java(MBeanAttributeInfo)
    @info = MBeanInfo.new name, description, attributes, nil, operations, nil
  end

  # Retrieve the value of the requested attribute (where attribute is a 
  # javax.management.Attribute class)
  def getAttribute(attribute)
    send("jmx_get_"+attribute.downcase)
  end
  
  def getAttributes(attributes)
    attrs = javax.management.AttributeList.new
    attributes.each { |attribute| attrs.add(getAttribute(attribute)) } 
    attrs
  end
  
  def getMBeanInfo; @info; end
  
  def invoke(actionName, params=nil, signature=nil)
    send(actionName, *params)
  end

  def setAttribute(attribute)
    send("jmx_set_#{attribute.name.downcase}", attribute.value)   
  end
  
  def setAttributes(attributes)  
    attributes.each { |attribute| setAttribute attribute}
  end
  
  def to_s; toString; end
  def inspect; toString; end
  def toString; "#@info.class_name: #@info.description"; end
end
