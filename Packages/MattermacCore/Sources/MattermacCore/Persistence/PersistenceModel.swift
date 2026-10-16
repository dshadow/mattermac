import CoreData
import Foundation

/// Keep released versions immutable. V2 adds optional creation metadata via lightweight migration.
enum PersistenceModel {
  static func make(version: Int = 2, durable: Bool = false) -> NSManagedObjectModel {
    let model = NSManagedObjectModel()
    model.versionIdentifiers = ["Mattermac-\(durable ? "Outgoing" : "Cache")-\(version)"]
    let entity = NSEntityDescription()
    entity.name = "Record"
    entity.managedObjectClassName = "NSManagedObject"
    var fields: [(String, NSAttributeType, Bool)] = [
      ("kind", .stringAttributeType, false), ("id", .stringAttributeType, false),
      ("channelID", .stringAttributeType, false), ("rootID", .stringAttributeType, false),
      ("sortAt", .integer64AttributeType, false), ("revision", .integer64AttributeType, false),
      ("isTombstone", .booleanAttributeType, false), ("payload", .binaryDataAttributeType, true),
      ("accessedAt", .dateAttributeType, false), ("sequence", .integer64AttributeType, false),
    ]
    if version >= 2 { fields.append(("createdAt", .dateAttributeType, true)) }
    entity.properties = fields.map { name, type, optional in
      let attribute = NSAttributeDescription()
      attribute.name = name
      attribute.attributeType = type
      attribute.isOptional = optional
      if type == .stringAttributeType { attribute.defaultValue = "" }
      if type == .integer64AttributeType { attribute.defaultValue = 0 }
      if type == .booleanAttributeType { attribute.defaultValue = false }
      return attribute
    }
    entity.uniquenessConstraints = [["kind", "id"]]
    entity.indexes = [
      index("timeline", ["kind", "channelID", "sortAt", "id"], entity),
      index("thread", ["kind", "channelID", "rootID", "sortAt", "id"], entity),
      index("retention", ["kind", "accessedAt"], entity),
    ]
    model.entities = [entity]
    return model
  }

  private static func index(
    _ name: String, _ fields: [String], _ entity: NSEntityDescription
  ) -> NSFetchIndexDescription {
    NSFetchIndexDescription(
      name: name,
      elements: fields.map {
        NSFetchIndexElementDescription(
          property: entity.propertiesByName[$0]!, collationType: .binary)
      })
  }
}
