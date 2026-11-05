import CoreData
import SwiftData
import Testing
@testable import Moonee

struct CloudKitSchemaTests {
    /// Core Data's CloudKit mirroring rejects schemas with non-optional, non-default attributes,
    /// non-optional or inverse-less relationships, or unique constraints. Fails if a model breaks that.
    @Test func schemaIsCloudKitCompatible() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: Schema.mooneeModels))
        #expect(model.entities.count == Schema.mooneeModels.count)
        #expect(model.entitiesByName["Txn"]?.attributesByName["amount"]?.defaultValue as? Int == 0) // the check below is not vacuous
        var problems: [String] = []
        for entity in model.entities {
            if !entity.uniquenessConstraints.isEmpty { problems.append("\(entity.name!): unique constraint") }
            for (name, p) in entity.propertiesByName {
                if let a = p as? NSAttributeDescription, !a.isOptional, a.defaultValue == nil { problems.append("\(entity.name!).\(name): no default") }
                if let r = p as? NSRelationshipDescription {
                    if !r.isOptional { problems.append("\(entity.name!).\(name): required relationship") }
                    if r.inverseRelationship == nil { problems.append("\(entity.name!).\(name): no inverse") }
                }
            }
        }
        #expect(problems == [])
    }
}
