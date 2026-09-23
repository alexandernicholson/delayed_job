# frozen_string_literal: true

require "test_helper"

class PerformableMethodTest < ActiveSupport::TestCase
  class Target
    attr_reader :label

    def initialize(label)
      @label = label
    end

    def shout(point, other)
      "#{label}#{point.x}#{point.y}#{other.label}"
    end

    def ==(other)
      other.is_a?(Target) && other.label == label
    end
  end

  Point = Struct.new(:x, :y)
  Coordinate = Data.define(:lat, :lng)

  setup do
    @method = Delayed::PerformableMethod.new(+"foo", :count, [ "o" ])
  end

  test "exposes object, method_name and args" do
    assert_equal "foo", @method.object
    assert_equal :count, @method.method_name
    assert_equal [ "o" ], @method.args

    @method.object = "bar"
    @method.method_name = :size
    @method.args = []
    assert_equal 3, @method.perform
  end

  test "stores the method name as a symbol" do
    assert_equal :count, Delayed::PerformableMethod.new("foo", "count", [ "o" ]).method_name
  end

  test "perform calls the method on the object" do
    @method.object.expects(:count).with("o").returns(2)

    assert_equal 2, @method.perform
  end

  test "perform does nothing if object is nil" do
    @method.object = nil

    assert_nothing_raised { assert_nil @method.perform }
  end

  test "raises a NoMethodError if target method doesn't exist" do
    error = assert_raises(NoMethodError) { Delayed::PerformableMethod.new(Object, :method_that_does_not_exist, []) }

    assert_equal "undefined method `method_that_does_not_exist' for Object", error.message
  end

  test "does not raise NoMethodError if target method is private" do
    clazz = Class.new do
      def private_method; end
      private :private_method
    end

    assert_nothing_raised { Delayed::PerformableMethod.new(clazz.new, :private_method, []) }
  end

  test "raises ArgumentError for new records" do
    story = Story.new(text: "hello")

    error = assert_raises(ArgumentError) { story.delay.tell }
    assert_equal "job cannot be created for non-persisted record: #{story.inspect}", error.message
  end

  test "raises ArgumentError for destroyed records" do
    story = Story.create(text: "hello")
    story.destroy

    error = assert_raises(ArgumentError) { story.delay.tell }
    assert_equal "job cannot be created for non-persisted record: #{story.inspect}", error.message
  end

  test "display_name returns class_name#method_name for instance methods" do
    assert_equal "String#count", Delayed::PerformableMethod.new("foo", :count, [ "o" ]).display_name
  end

  test "display_name returns class_name.method_name for class methods" do
    assert_equal "Class.inspect", Delayed::PerformableMethod.new(Class, :inspect, []).display_name
  end

  test "method returns the object's method" do
    method = @method.method(:count)

    assert_same @method.object, method.receiver
    assert_equal :count, method.name
  end

  test "method_missing and respond_to? delegate to the object" do
    assert_equal 3, @method.length
    assert_respond_to @method, :upcase
    assert_not @method.respond_to?(:no_such_method)

    clazz = Class.new do
      private
        def hidden; end
    end
    method = Delayed::PerformableMethod.new(clazz.new, :hidden, [])
    assert method.respond_to?(:hidden, true)
    assert_not method.respond_to?(:hidden)
  end

  test "delegates failure hook to object" do
    method = Delayed::PerformableMethod.new(+"object", :size, [])
    method.object.expects(:failure)

    method.failure
  end

  %w[ before after success ].each do |hook|
    test "delegates #{hook} hook to object" do
      story = Story.create(text: "hello")
      job = story.delay.tell

      story.expects(hook).with(job)
      job.invoke_job
    end

    test "delegates #{hook} hook to object when delay_jobs is false" do
      Delayed::Worker.delay_jobs = false
      story = Story.create(text: "hello")

      story.expects(hook).with(instance_of(Delayed::Job))
      story.delay.tell
    end
  end

  test "delegates enqueue hook to object" do
    story = Story.create(text: "hello")

    story.expects(:enqueue).with(instance_of(Delayed::Job))
    story.delay.tell
  end

  test "delegates error hook to object" do
    story = Story.create(text: "hello")
    job = story.delay.tell

    story.expects(:error).with(job, instance_of(RuntimeError))
    story.expects(:tell).raises(RuntimeError)
    assert_raises(RuntimeError) { job.invoke_job }
  end

  test "delegates error hook to object when delay_jobs is false" do
    Delayed::Worker.delay_jobs = false
    story = Story.create(text: "hello")

    story.expects(:error).with(instance_of(Delayed::Job), instance_of(RuntimeError))
    story.expects(:tell).raises(RuntimeError)
    assert_raises(RuntimeError) { story.delay.tell }
  end

  test "serializes through Active Job with a registered serializer" do
    serialized = ActiveJob::Arguments.serialize([ Delayed::PerformableMethod.new("foo", :count, [ "o" ]) ]).first

    assert_equal "Delayed::PerformableMethodSerializer", serialized["_aj_serialized"]
    assert_equal "Delayed::PerformableMethod", serialized["class"]
    assert_equal "count", serialized["method_name"]
  end

  test "round-trips strings, symbols and hashes" do
    method = round_trip(Delayed::PerformableMethod.new("foo", :count, [ "o", :sym, { "a" => 1, b: [ 2, :c ] } ]))

    assert_equal Delayed::PerformableMethod, method.class
    assert_equal "foo", method.object
    assert_equal :count, method.method_name
    assert_equal [ "o", :sym, { "a" => 1, b: [ 2, :c ] } ], method.args
  end

  test "round-trips hash args" do
    method = round_trip(Delayed::PerformableMethod.new("text", :length, {}))

    assert_equal({}, method.args)
    assert_equal 4, method.perform
  end

  test "round-trips classes and modules by name" do
    assert_equal Delayed::Worker, round_trip(Delayed::PerformableMethod.new(Delayed::Worker, :reset, [])).object
    assert_equal Delayed, round_trip(Delayed::PerformableMethod.new(Delayed, :name, [])).object
  end

  test "round-trips records by GlobalID and reloads them" do
    story = Story.create(text: "hello")
    serialized = ActiveJob::Arguments.serialize([ Delayed::PerformableMethod.new(story, :tell, []) ]).first

    assert_equal story.to_global_id.to_s, serialized["object"]["_aj_globalid"]
    story.text = "goodbye"
    story.save!

    loaded = ActiveJob::Arguments.deserialize([ serialized ]).first
    assert_equal "goodbye", loaded.perform
  end

  test "raises a deserialization error when the record is gone" do
    story = Story.create(text: "hello")
    serialized = ActiveJob::Arguments.serialize([ Delayed::PerformableMethod.new(story, :tell, []) ])
    story.destroy

    assert_raises(ActiveJob::DeserializationError) { ActiveJob::Arguments.deserialize(serialized) }
  end

  test "keeps the PerformableMethod subclass" do
    subclass = Delayed::PerformableMailer

    assert_equal subclass, round_trip(subclass.new("foo", :count, [ "o" ])).class
  end

  test "refuses to load classes that are not performable methods" do
    serialized = ActiveJob::Arguments.serialize([ Delayed::PerformableMethod.new("foo", :count, [ "o" ]) ])
    serialized.first["class"] = "String"

    assert_raises(ActiveJob::DeserializationError) { ActiveJob::Arguments.deserialize(serialized) }
  end

  test "plain objects and structs serialize inside Delayed::JobWrapper payloads" do
    method = Delayed::PerformableMethod.new(Target.new("hi"), :shout, [ Point.new(1, 2), Target.new("arg") ])

    loaded = Delayed::Serializers::ObjectSerializer.permit { round_trip(method) }

    assert_equal Target.new("hi"), loaded.object
    assert_equal [ Point.new(1, 2), Target.new("arg") ], loaded.args
    assert_equal "hi12arg", loaded.perform
  end

  test "Data objects serialize inside Delayed::JobWrapper payloads" do
    method = Delayed::PerformableMethod.new(Coordinate.new(lat: 1.5, lng: :east), :to_h, [])

    loaded = Delayed::Serializers::ObjectSerializer.permit { round_trip(method) }

    assert_equal Coordinate.new(lat: 1.5, lng: :east), loaded.object
    assert_equal({ lat: 1.5, lng: :east }, loaded.perform)
  end

  test "plain objects keep Active Job's unsupported type error outside job payloads" do
    error = assert_raises(ActiveJob::SerializationError) { ActiveJob::Arguments.serialize([ Target.new("hi") ]) }
    assert_equal "Unsupported argument type: PerformableMethodTest::Target", error.message

    assert_raises(ActiveJob::SerializationError) { ActiveJob::Arguments.serialize([ Object.new ]) }
  end

  test "plain object serialization defers to other serializers" do
    money = Class.new(ActiveJob::Serializers::ObjectSerializer) do
      def serialize?(argument)
        argument.is_a?(PerformableMethodTest::Target) && argument.label == "money"
      end

      def serialize(_target)
        super("amount" => 5)
      end

      def deserialize(_hash)
        PerformableMethodTest::Target.new("from money")
      end

      def klass
        @klass ||= Class.new
      end
    end
    stub_const(PerformableMethodTest, :MoneySerializer, money) do
      previous = ActiveJob::Serializers.serializers.to_a
      ActiveJob::Serializers.add_serializers(PerformableMethodTest::MoneySerializer)
      begin
        serialized = Delayed::Serializers::ObjectSerializer.permit { ActiveJob::Arguments.serialize([ Target.new("money") ]) }
        assert_equal "PerformableMethodTest::MoneySerializer", serialized.first["_aj_serialized"]
      ensure
        ActiveJob::Serializers.serializers = previous
      end
    end
  end

  test "plain object serialization refuses core objects whose state it cannot see" do
    PerformableMethodTest.const_set(:CustomError, Class.new(StandardError))

    [ Set.new([ 1, 2 ]), /pattern/, RuntimeError.new("boom"), PerformableMethodTest::CustomError.new("x") ].each do |value|
      assert_raises(ActiveJob::SerializationError, value.inspect) do
        Delayed::Serializers::ObjectSerializer.permit { ActiveJob::Arguments.serialize([ value ]) }
      end
    end
  ensure
    PerformableMethodTest.send(:remove_const, :CustomError) if PerformableMethodTest.const_defined?(:CustomError, false)
  end

  test "plain object deserialization refuses classes it does not serialize" do
    serialized = Delayed::Serializers::ObjectSerializer.permit { ActiveJob::Arguments.serialize([ Target.new("hi") ]) }
    serialized.first["class"] = "Set"

    assert_raises(ActiveJob::DeserializationError) { ActiveJob::Arguments.deserialize(serialized) }
  end

  test "plain object serialization refuses anonymous classes" do
    assert_raises(ActiveJob::SerializationError) do
      Delayed::Serializers::ObjectSerializer.permit { ActiveJob::Arguments.serialize([ Class.new.new ]) }
    end
  end

  test "the module serializer round-trips named modules and refuses anonymous ones" do
    serializer = Delayed::Serializers::ModuleSerializer

    serialized = serializer.serialize(Delayed::Worker)
    assert_equal({ "_aj_serialized" => "Delayed::Serializers::ModuleSerializer", "value" => "Delayed::Worker" }, serialized)
    assert_equal Delayed::Worker, serializer.deserialize(serialized)
    assert serializer.serialize?(Delayed)
    assert_equal Module, serializer.instance.klass
    assert_raises(ActiveJob::SerializationError) { serializer.serialize(Class.new) }
  end

  test "Mongoid documents become GlobalID-identifiable delay targets" do
    fake_mongoid = Module.new { const_set(:Document, Module.new) }
    Object.const_set(:Mongoid, fake_mongoid)
    load File.expand_path("../lib/delayed/mongoid.rb", __dir__)

    document_class = Class.new do
      include ::Mongoid::Document
      cattr_accessor :documents, default: {}
      attr_reader :id

      def self.name
        "PerformableMethodTest::FakeDocument"
      end

      def self.find(id)
        documents.fetch(id)
      end

      def initialize(id)
        @id = id
        documents[id] = self
      end

      def title
        "document #{id}"
      end
    end
    PerformableMethodTest.const_set(:FakeDocument, document_class)

    assert_includes ::Mongoid::Document.ancestors, GlobalID::Identification
    loaded = round_trip(Delayed::PerformableMethod.new(document_class.new("abc"), :title, []))
    assert_equal "document abc", loaded.perform
  ensure
    PerformableMethodTest.send(:remove_const, :FakeDocument) if PerformableMethodTest.const_defined?(:FakeDocument, false)
    Object.send(:remove_const, :Mongoid) if Object.const_defined?(:Mongoid, false)
  end

  private
    def round_trip(value)
      ActiveJob::Arguments.deserialize(ActiveJob::Arguments.serialize([ value ])).first
    end

    def stub_const(scope, name, value)
      scope.const_set(name, value)
      yield
    ensure
      scope.send(:remove_const, name)
    end
end
