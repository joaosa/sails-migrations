sets = require('simplesets')
SchemaMigration = require('./schema_migration')
MigrationPath = require('./migration_path')
MigrationRunner = require('./migration_runner')
AdapterWrapper = require('./adapter_wrapper')
_ = require('lodash')
Promise = require('bluebird')

#This is a replica of https://github.com/rails/docrails/blob/master/activerecord/lib/active_record/migration.rb#L764
class Migrator
  constructor: (@adapter, @direction, @_migrations, @versions, @targetVersion=null)->
    #TODO: Make sure the adapter supports migrations
    @migrated = new sets.Set(@versions)
    @validate(@_migrations)
    
  validate: (migrations)->
    #TODO: 
    #name ,= migrations.group_by(&:name).find { |_,v| v.length > 1 }
    #raise DuplicateMigrationNameError.new(name) if name

    #version ,= migrations.group_by(&:version).find { |_,v| v.length > 1 }
    #raise DuplicateMigrationVersionError.new(version) if version

  @migrate: (adapter, migrationsPaths, targetVersion, cb)-> 
    if !targetVersion
      @move('up', adapter, migrationsPaths, targetVersion, cb)
    else 
      @currentVersion( (err, currentVersion)=>
        return cb(err) if err
        if currentVersion == 0 && targetVersion == 0
          cb(null, [])
        else if currentVersion > targetVersion
          @move('down', adapter, migrationsPaths, targetVersion, cb)
        else
          @move('up', migrationsPaths, targetVersion, cb)
      )

  @rollback: (adapter, migrationsPaths, steps, cb)->
    steps = 1 unless steps
    direction = 'down'
    @calculateTargetVersion(adapter, direction, migrationsPaths, steps).then((targetVersion)=>
      @move(direction, adapter, migrationsPaths, targetVersion, cb)
    ).catch(cb)

  @move: (direction, adapter, migrationsPaths, targetVersion, cb)->
    @migrations(migrationsPaths, (err, migrations)=>
      return cb(err) if err

      SchemaMigration.getAllVersions(adapter, (err, versions)=>
        return cb(err) if err

        migrator = new Migrator(adapter, direction, migrations, versions, targetVersion)
        migrator.migrate(cb)
      )
    )

  @migrations: (migrationsPaths, cb)->
    MigrationPath.allMigrationFilesParsed(migrationsPaths, (err, migrations)->
      return cb(err) if err

      migrationsRunners = _.map(migrations, (migration)-> new MigrationRunner(migration))
      migrationsRunners = _.sortBy(migrationsRunners, (m)-> m.version())
      cb(null, migrationsRunners)
    )

  @calculateTargetVersion: (adapter, direction, migrationsPaths, steps)->
    resolver = Promise.defer()
    @migrations(migrationsPaths, (err, migrations)=>
      return resolver(reject) if err

      dummyMigrator = new Migrator(adapter, direction, migrations)

      targetVersion = null
      startIndex = dummyMigrator.start()
      if startIndex?
        finish = dummyMigrator.getMigrationByIndex(startIndex + steps)
        targetVersion = if finish? then finish.version() else 0

      resolver.resolve(targetVersion)
    )
    resolver.promise
    ###
migrator = self.new(direction, migrations(migrations_paths))
        start_index = migrator.migrations.index(migrator.current_migration)

        if start_index
          finish = migrator.migrations[start_index + steps]
          version = finish ? finish.version : 0
          send(direction, migrations_paths, version)
        end
###

  currentVersion: ->
    migratedSetAsArray = @migrated.array()
    if _.isEmpty(migratedSetAsArray)
      0
    else
      _.max(migratedSetAsArray)

  currentMigration: ->
    _.detect(@migrations(), (migration)=> migration.version() == @currentVersion())

  currentMigrationIndex: ->
    index = _.indexOf(@migrations(), @currentMigration())
    if index > -1 then index else undefined

  targetMigration: ->
    _.detect(@migrations(), (migration)=> migration.version() == @targetVersion)

  targetMigrationIndex: ->
    index = _.indexOf(@migrations(), @targetMigration())
    if index > -1 then index else undefined

  getMigrationByIndex: (index)->
    @migrations()[index]

  migrate: (cb)->
    if !@targetMigration() && @targetVersion && @targetVersion > 0
      return cb("Unknown migration version error #{@targetVersion}")

    executeMigrationInTransaction = Promise.promisify(@executeMigrationInTransaction.bind(@))

    promises = _.map(@runnable(), (migration)=>
      #TODO: Figure out how to do logging properly
      #console.log "Migrating to #{migration.name()} (#{migration.version()})"
      
      executeMigrationInTransaction(migration, @direction)

      #rescue => e
      #canceled_msg = use_transaction?(migration) ? "this and " : ""
      #raise StandardError, "An error has occurred, #{canceled_msg}all later migrations canceled:\n\n#{e}", e.backtrace
      #end
    )

    #TODO: We need to resolve the errors properly
    Promise.all(promises).then( (errors)->
      cb()
    )

  executeMigrationInTransaction: (migration, direction, cb)->
    ourAdapter = new AdapterWrapper(@adapter)
    migration.migrate(ourAdapter, direction, (err)=>
      return cb(err) if err
      @recordVersionStateAfterMigrating(migration.version()).then( (version)->
        cb(null, version)
      )
    )

  recordVersionStateAfterMigrating: (version)->
    resolver = Promise.defer()
    if @isDown()
      @migrated.remove(version)
      Promise.promisify(SchemaMigration.deleteAllByVersion.bind(SchemaMigration))(@adapter, version)
    else
      @migrated.add(version)
      SchemaMigration.create(@adapter, { version: version }, (err, model)=>
        resolver.reject(err) if err
        resolver.resolve(model)
      )
      resolver.promise

  migrations: ->
    clone = _.clone(@_migrations)
    if @isDown() then clone.reverse() else clone #for some reason in rails they sort it by version here, even though it already should come sorted..
      
  runnable: ->
    start = @start()
    finish = @finish() + 1
    runnable = @migrations().slice(start, finish)
    console.log 'start', start, 'finish', finish
    console.log 'runnable count', _.size(runnable), @direction, @targetVersion, @migrations()
    runnable = _(runnable)
    if @isUp
      runnable.reject(@ran.bind(@)).value()
    else
      # skip the last migration if we're headed down, but not ALL the way down
      runnable.pop if @targetMigration()
      runnable.filter(@ran.bind(@)).value()

  start: ->
    if @isUp() then 0 else (@currentMigrationIndex() || 0)

  finish: ->
    if @targetMigrationIndex()
      @targetMigrationIndex() - 1
    else
      (@migrations().length - 1)
    
  isUp: ->
    @direction == 'up'

  isDown: ->
    @direction == 'down'

  ran: (migration)->
    _.contains(@migrated, migration.version())

module.exports = Migrator
