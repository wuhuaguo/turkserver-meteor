myGroup = "group1"
otherGroup = "group2"
username = "fooser"

basicInsertCollection = new Meteor.Collection("basicInsert")
twoGroupCollection = new Meteor.Collection("twoGroup")

if Meteor.isServer
  groupingCollections = {}

  groupingCollections.basicInsert = basicInsertCollection
  groupingCollections.twoGroup = twoGroupCollection

  hookCollection = (collection) ->
    collection._insecure = true

    # Enable direct insert - comes before the other insert hook modifies groupId
    collection.before.insert (userId, doc) ->
      if doc._direct
        delete doc._direct
        @_super.call(@context, doc)
        return false
      return

    # Attach the turkserver hooks to the collection
    TurkServer.registerCollection(collection)

    # Enable direct find which removes the added _groupId after the find hook
    # Also triggers the direct find for the remove hook
    collection.before.find (userId, selector, options) ->
      if selector._direct
        delete selector._direct
        delete selector._groupId # This is what I added before

if Meteor.isClient
  hookCollection = (collection) -> TurkServer.registerCollection(collection)

hookCollection basicInsertCollection
hookCollection twoGroupCollection

if Meteor.isServer
  # Add a group to anyone who logs in
  Meteor.users.find("status.online": true).observeChanges
    added: (id) ->
      TurkServer.addUserToGroup(id, myGroup)

  # We create the collections in the publisher (instead of using a method or
  # something) because if we made them with a method, we'd need to follow the
  # method with some subscribes, and it's possible that the method call would
  # be delayed by a wait method and the subscribe messages would be sent before
  # it and fail due to the collection not yet existing. So we are very hacky
  # and use a publish.
  Meteor.publish "groupingTests", ->
    return unless @userId

    basicInsertCollection.remove(_direct: true) # Also uses the find feature here
    twoGroupCollection.remove(_direct: true)

    cursors = [ basicInsertCollection.find(), twoGroupCollection.find() ]

    Meteor._debug "grouping publication activated"

    twoGroupCollection.insert
      _direct: true
      _groupId: myGroup
      a: 1

    twoGroupCollection.insert
      _direct: true
      _groupId: otherGroup
      a: 1

    Meteor._debug "collections configured"

    return cursors

  Meteor.methods
    serverUpdate: (name, selector, mutator) ->
      return groupingCollections[name].update(selector, mutator)
    serverRemove: (name, selector) ->
      return groupingCollections[name].remove(selector)
    getCollection: (name, selector) ->
      return groupingCollections[name].find(_.extend(selector || {}, {_direct: true})).fetch()
    getMyCollection: (name, selector) ->
      return groupingCollections[name].find(selector || {}).fetch()
    printCollection: (name) ->
      console.log groupingCollections[name].find(_direct: true).fetch()
    printMyCollection: (name) ->
      console.log groupingCollections[name].find().fetch()

if Meteor.isClient
  # Ensure we are logged in before running these tests
  Tinytest.addAsync "grouping - verify login", (test, next) ->
    InsecureLogin.ready next

  ###
    These tests need to all async so they are in the right order
  ###

  # Ensure that the group id has been recorded before subscribing
  Tinytest.addAsync "grouping - received group id", (test, next) ->
    Deps.autorun (c) ->
      record = Meteor.user()
      if record?.turkserver?.group
        c.stop()
        next()

  Tinytest.addAsync "grouping - test subscriptions ready", (test, next) ->
    handle = Meteor.subscribe("groupingTests")
    Deps.autorun (c) ->
      if handle.ready()
        c.stop()
        next()

  Tinytest.addAsync "grouping - local empty find", (test, next) ->
    test.equal basicInsertCollection.find().count(), 0
    next()

  testAsyncMulti "grouping - basic insert", [
    (test, expect) ->
      id = basicInsertCollection.insert { a: 1 }, expect (err, res) ->
        test.isFalse err, JSON.stringify(err)
        test.equal res, id
  , (test, expect) ->
      test.equal basicInsertCollection.find({a: 1}).count(), 1
      test.equal basicInsertCollection.findOne(a: 1)._groupId, myGroup
  ]

  testAsyncMulti "grouping - find from two groups", [ (test, expect) ->
    test.equal twoGroupCollection.find().count(), 1
    Meteor.call "getCollection", "twoGroup", expect (err, res) ->
      test.isFalse err
      test.equal res.length, 2
  ]

  testAsyncMulti "grouping - insert into two groups", [
    (test, expect) ->
      twoGroupCollection.insert {a: 2}, expect (err) ->
        test.isFalse err, JSON.stringify(err)
        test.equal twoGroupCollection.find().count(), 2
  , (test, expect) ->
      Meteor.call "getMyCollection", "twoGroup", expect (err, res) ->
        test.isFalse err
        test.equal res.length, 2
  , (test, expect) -> # Ensure that the other half is still on the server
      Meteor.call "getCollection", "twoGroup", expect (err, res) ->
        test.isFalse err, JSON.stringify(err)
        test.equal res.length, 3
  ]

  testAsyncMulti "grouping - server update identical keys across groups", [
    (test, expect) ->
      Meteor.call "serverUpdate", "twoGroup",
        {a: 1},
        $set: { b: 1 }, expect (err, res) ->
          test.isFalse err
  , (test, expect) -> # Make sure that the other group's record didn't get updated
      Meteor.call "getCollection", "twoGroup", expect (err, res) ->
        test.isFalse err
        _.each res, (doc) ->
          if doc.a is 1 and doc._groupId is myGroup
            test.equal doc.b, 1
          else
            test.isFalse doc.b
  ]

  testAsyncMulti "grouping - server remove identical keys across groups", [
    (test, expect) ->
      Meteor.call "serverRemove", "twoGroup",
        {a: 1}, expect (err, res) ->
          test.isFalse err
  , (test, expect) -> # Make sure that the other group's record didn't get updated
      Meteor.call "getCollection", "twoGroup", {a: 1}, expect (err, res) ->
        test.isFalse err
        test.equal res.length, 1
        test.equal res[0].a, 1
  ]

