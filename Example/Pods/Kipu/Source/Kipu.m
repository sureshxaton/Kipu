//
//  Kipu.m
//
//  Copyright (c) 2014 Elvis Nuñez. All rights reserved.
//

#import "Kipu.h"

#import "NSDictionary+ANDYSafeValue.h"
#import "NSManagedObject+HYPPropertyMapper.h"
#import "NSManagedObject+ANDYMapChanges.h"
#import "ANDYDataManager.h"

@interface NSManagedObject (Kipu)

- (NSManagedObject *)kipu_safeObjectInContext:(NSManagedObjectContext *)context;

- (NSArray *)kipu_relationships;

- (void)kipu_processRelationshipsUsingDictionary:(NSDictionary *)objectDict
                                       andParent:(NSManagedObject *)parent;

- (void)kipu_processRelationship:(NSRelationshipDescription *)relationship
                 usingDictionary:(NSDictionary *)objectDict
                       andParent:(NSManagedObject *)parent;
@end

@implementation Kipu

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
            completion:(void (^)(NSError *error))completion
{
    [self processChanges:changes
         usingEntityName:entityName
               predicate:nil
              completion:completion];
}

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
             predicate:(NSPredicate *)predicate
            completion:(void (^)(NSError *error))completion
{
    [ANDYDataManager performInBackgroundContext:^(NSManagedObjectContext *context) {

        [self processChanges:changes
             usingEntityName:entityName
                   predicate:predicate
                      parent:nil
                   inContext:context
                  completion:completion];
    }];
}

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
                parent:(NSManagedObject *)parent
            completion:(void (^)(NSError *error))completion
{
    [ANDYDataManager performInBackgroundContext:^(NSManagedObjectContext *context) {

        NSManagedObject *safeParent = [parent kipu_safeObjectInContext:context];
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"%K = %@", parent.entity.name, safeParent];

        [self processChanges:changes
             usingEntityName:entityName
                   predicate:predicate
                      parent:safeParent
                   inContext:context
                  completion:completion];
    }];
}

+ (void)processChanges:(NSArray *)changes
       usingEntityName:(NSString *)entityName
             predicate:(NSPredicate *)predicate
                parent:(NSManagedObject *)parent
             inContext:(NSManagedObjectContext *)context
            completion:(void (^)(NSError *error))completion
{
    [NSManagedObject andy_mapChanges:changes
                      usingPredicate:predicate
                           inContext:context
                       forEntityName:entityName
                            inserted:^(NSDictionary *objectDict) {

                                NSManagedObject *created = [NSEntityDescription insertNewObjectForEntityForName:entityName
                                                                                         inManagedObjectContext:context];
                                [created hyp_fillWithDictionary:objectDict];
                                [created kipu_processRelationshipsUsingDictionary:objectDict andParent:parent];

                            } updated:^(NSDictionary *objectDict, NSManagedObject *object) {

                                [object hyp_fillWithDictionary:objectDict];
                                [object kipu_processRelationshipsUsingDictionary:objectDict andParent:parent];

                            }];

    NSError *error = nil;
    [context save:&error];
    if (error) NSLog(@"ANDYNetworking (error while saving %@): %@", entityName, [error description]);

    if (completion) completion(error);
}

+ (NSManagedObject *)safeObjectInContext:(NSManagedObjectContext *)context
                              entityName:(NSString *)entityName
                                remoteID:(id)remoteID
{
    NSError *error = nil;
    NSFetchRequest *request = [[NSFetchRequest alloc] initWithEntityName:entityName];
    NSString *localKey = [NSString stringWithFormat:@"%@ID", [entityName lowercaseString]];
    request.predicate = [NSPredicate predicateWithFormat:@"%K = %@", localKey, remoteID];

    NSArray *objects = [context executeFetchRequest:request error:&error];
    if (error) NSLog(@"parentError: %@", error);
    return [objects firstObject];
}

@end

@implementation NSManagedObject (Kipu)

- (NSManagedObject *)kipu_safeObjectInContext:(NSManagedObjectContext *)context
{
    NSString *localKey = [NSString stringWithFormat:@"%@ID", [self.entity.name lowercaseString]];
    NSString *remoteID = [self valueForKey:localKey];

    return [Kipu safeObjectInContext:context entityName:self.entity.name remoteID:remoteID];
}

- (NSArray *)kipu_relationships
{
    NSMutableArray *relationships = [NSMutableArray array];

    for (id propertyDescription in [self.entity properties]) {

        if ([propertyDescription isKindOfClass:[NSRelationshipDescription class]]) {
            [relationships addObject:propertyDescription];
        }
    }

    return relationships;
}

- (void)kipu_processRelationshipsUsingDictionary:(NSDictionary *)objectDict
                                       andParent:(NSManagedObject *)parent
{
    NSArray *relationships = [self kipu_relationships];

    for (NSRelationshipDescription *relationship in relationships) {
        if (relationship.isToMany) {

            [self kipu_processRelationship:relationship usingDictionary:objectDict andParent:parent];

        } else {
            if (parent) {
                [self setValue:parent forKey:relationship.name];
            } else {
                NSString *entityName = [relationship.name capitalizedString];
                NSDictionary *filteredObjectDict = [objectDict andy_valueForKey:relationship.name];
                if (!filteredObjectDict) continue;

                NSManagedObject *object = [Kipu safeObjectInContext:self.managedObjectContext
                                                         entityName:entityName
                                                           remoteID:[filteredObjectDict andy_valueForKey:@"id"]];
                if (object) {
                    [object hyp_fillWithDictionary:filteredObjectDict];
                } else {
                    object = [NSEntityDescription insertNewObjectForEntityForName:entityName
                                                           inManagedObjectContext:self.managedObjectContext];
                    [object hyp_fillWithDictionary:filteredObjectDict];
                }

                [self setValue:object forKey:relationship.name];
            }
        }
    }
}

- (void)kipu_processRelationship:(NSRelationshipDescription *)relationship
                 usingDictionary:(NSDictionary *)objectDict
                       andParent:(NSManagedObject *)parent
{
    NSArray *childs = [objectDict andy_valueForKey:relationship.name];
    if (!childs) {
        BOOL hasValidManyToManyRelationship = (parent &&
                                               relationship.inverseRelationship.isToMany &&
                                               [parent.entity.name isEqualToString:relationship.destinationEntity.name]);
        if (hasValidManyToManyRelationship) {
            NSMutableSet *relatedObjects = [self mutableSetValueForKey:relationship.name];
            [relatedObjects addObject:parent];
            [self setValue:relatedObjects forKey:relationship.name];
        }

        return;
    }

    NSString *childEntityName = relationship.destinationEntity.name;
    NSString *inverseEntityName = relationship.inverseRelationship.name;
    NSPredicate *childPredicate;

    if (relationship.inverseRelationship.isToMany) {
        NSArray *childIDs = [childs valueForKey:@"id"];
        NSString *destinationKey = [NSString stringWithFormat:@"%@ID", [childEntityName lowercaseString]];
        if (childIDs.count == 1) {
            childPredicate = [NSPredicate predicateWithFormat:@"%K = %@", destinationKey, [[childs valueForKey:@"id"] firstObject]];
        } else {
            childPredicate = [NSPredicate predicateWithFormat:@"ANY %K.%K = %@", relationship.name, destinationKey, [childs valueForKey:@"id"]];
        }
    } else {
        childPredicate = [NSPredicate predicateWithFormat:@"%K = %@", inverseEntityName, self];
    }

    [Kipu processChanges:childs
         usingEntityName:childEntityName
               predicate:childPredicate
                  parent:self
               inContext:self.managedObjectContext
              completion:nil];
}

@end
