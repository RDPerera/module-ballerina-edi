// Copyright (c) 2026 WSO2 LLC. (http://www.wso2.com) All Rights Reserved.
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/log;

// EDI formats reuse the same segment code for definitions with different meanings and rely on a
// qualifier value to identify each one (e.g. X12 834 uses REF*0F, REF*1L and REF*17 for three
// different member-level definitions; EDIFACT RFF carries the equivalent qualifier inside the
// C506 composite). Schema nodes can declare the legal codes of an element with `values`, and opt
// the element into segment matching with `discriminator: true`. `values` on its own never affects
// matching — it is validated when writing EDI — so converters can attach full standard code lists
// without changing how existing messages parse.

# Checks whether the given input segment is an instance of the given segment schema.
#
# A segment matches when its code matches and, for every discriminator node in the schema
# (at field, component, or subcomponent level), the corresponding input value is present
# and contained in that node's `values` set. A missing or empty discriminator value never
# matches: a segment that does not carry its identity cannot claim a discriminated schema.
#
# + segSchema - Segment schema to match against
# + fields - Fields of the input segment
# + ediSchema - EDI schema providing the delimiters
# + return - True if the segment code and all discriminator constraints match
isolated function segmentMatches(EdiSegSchema segSchema, string[] fields, EdiSchema ediSchema) returns boolean {
    if fields.length() == 0 || segSchema.code != fields[0].trim() {
        return false;
    }
    foreach int i in 0 ..< segSchema.fields.length() {
        EdiFieldSchema fieldSchema = segSchema.fields[i];
        if !hasDiscriminator(fieldSchema) {
            continue;
        }
        // Raw fields align with schema fields by index, following the same convention as readSegment.
        string rawField = i < fields.length() ? fields[i] : "";
        if !fieldMatches(fieldSchema, rawField, ediSchema) {
            return false;
        }
    }
    return true;
}

isolated function segmentHasDiscriminator(EdiSegSchema segSchema) returns boolean {
    foreach EdiFieldSchema fieldSchema in segSchema.fields {
        if hasDiscriminator(fieldSchema) {
            return true;
        }
    }
    return false;
}

isolated function hasDiscriminator(EdiFieldSchema fieldSchema) returns boolean {
    if fieldSchema.discriminator {
        return true;
    }
    foreach EdiComponentSchema componentSchema in fieldSchema.components {
        if componentSchema.discriminator {
            return true;
        }
        foreach EdiSubcomponentSchema subcomponentSchema in componentSchema.subcomponents {
            if subcomponentSchema.discriminator {
                return true;
            }
        }
    }
    return false;
}

isolated function fieldMatches(EdiFieldSchema fieldSchema, string rawField, EdiSchema ediSchema) returns boolean {
    if fieldSchema.repeat {
        // Discriminators on repeating fields are rejected at schema load time.
        return true;
    }
    if fieldSchema.discriminator {
        // Schema load validation guarantees that a discriminator field is a simple field with values.
        if !valueInSet(rawField, fieldSchema.values) {
            return false;
        }
    }
    if fieldSchema.components.length() > 0 {
        string[]|Error components = split(rawField, ediSchema.delimiters.component);
        if components is Error {
            return false;
        }
        foreach int j in 0 ..< fieldSchema.components.length() {
            EdiComponentSchema componentSchema = fieldSchema.components[j];
            string rawComponent = j < components.length() ? components[j] : "";
            if componentSchema.discriminator && !valueInSet(rawComponent, componentSchema.values) {
                return false;
            }
            if componentSchema.subcomponents.length() > 0 && hasSubcomponentDiscriminator(componentSchema) {
                string[]|Error subcomponents = split(rawComponent, ediSchema.delimiters.subcomponent);
                if subcomponents is Error {
                    return false;
                }
                foreach int k in 0 ..< componentSchema.subcomponents.length() {
                    EdiSubcomponentSchema subcomponentSchema = componentSchema.subcomponents[k];
                    if !subcomponentSchema.discriminator {
                        continue;
                    }
                    string rawSubcomponent = k < subcomponents.length() ? subcomponents[k] : "";
                    if !valueInSet(rawSubcomponent, subcomponentSchema.values) {
                        return false;
                    }
                }
            }
        }
    }
    return true;
}

isolated function hasSubcomponentDiscriminator(EdiComponentSchema componentSchema) returns boolean {
    foreach EdiSubcomponentSchema subcomponentSchema in componentSchema.subcomponents {
        if subcomponentSchema.discriminator {
            return true;
        }
    }
    return false;
}

isolated function valueInSet(string value, string[]? allowedValues) returns boolean {
    if allowedValues is () {
        // Discriminators without values are rejected at schema load time; treated as non-matching defensively.
        return false;
    }
    string normalized = value.trim();
    if normalized == "" {
        return false;
    }
    return allowedValues.indexOf(normalized, 0) !is ();
}

# Validates a value against the `values` set of a schema node when writing EDI.
# Empty values are not validated here — presence rules are enforced by the `required` attribute.
#
# + value - Input value being written
# + allowedValues - The node's `values` set, if any
# + segTag - Tag of the containing segment schema (used in error messages)
# + nodeTag - Tag of the schema node (used in error messages)
# + return - Error if the value is not in the allowed set
isolated function validateAllowedValue(json value, string[]? allowedValues, string segTag, string nodeTag) returns Error? {
    if allowedValues is () {
        return;
    }
    string normalized = value.toString().trim();
    if normalized == "" {
        return;
    }
    if allowedValues.indexOf(normalized, 0) is () {
        return error Error(string `Input value is not allowed by the value constraint of the schema.
            Segment: ${segTag}, Element: ${nodeTag}, Input value: ${value.toString()}, Allowed values: ${allowedValues.toString()}`);
    }
}

# Validates the value constraints of a schema at load time and lints same-code sibling
# definitions for missing or overlapping discriminators.
#
# + schema - Schema to validate
# + return - Error if a discriminator is declared without values, on a repeating field,
# or on a node whose value is not a simple value (composite fields and components with subcomponents)
isolated function validateValueConstraints(EdiSchema schema) returns Error? {
    check validateUnitList(schema.segments);
    EdiEnvelopeSchema? envelope = schema.envelope;
    if envelope is EdiEnvelopeSchema {
        check validateUnitList(envelope.interchange.header);
        check validateUnitList(envelope.interchange.trailer);
        EdiEnvelopeLevel? groupLevel = envelope.group;
        if groupLevel is EdiEnvelopeLevel {
            check validateUnitList(groupLevel.header);
            check validateUnitList(groupLevel.trailer);
        }
        check validateUnitList(envelope.'transaction.header);
        check validateUnitList(envelope.'transaction.trailer);
    }
}

isolated function validateUnitList(EdiUnitSchema[] units) returns Error? {
    foreach EdiUnitSchema unit in units {
        if unit is EdiSegSchema {
            check validateSegmentValueConstraints(unit);
        } else if unit is EdiSegGroupSchema {
            check validateUnitList(unit.segments);
        }
        // Segment references are resolved during denormalization before this validation runs.
    }
    lintSameCodeSiblings(units);
}

isolated function validateSegmentValueConstraints(EdiSegSchema segSchema) returns Error? {
    foreach EdiFieldSchema fieldSchema in segSchema.fields {
        if fieldSchema.discriminator {
            if fieldSchema.repeat {
                return error Error(string `Discriminators are not supported on repeating fields.
                    Segment: ${segSchema.tag}, Field: ${fieldSchema.tag}`);
            }
            if fieldSchema.components.length() > 0 {
                return error Error(string `Discriminators on composite fields must be declared on the component holding the value.
                    Segment: ${segSchema.tag}, Field: ${fieldSchema.tag}`);
            }
            check requireValues(fieldSchema.values, segSchema.tag, fieldSchema.tag);
        }
        foreach EdiComponentSchema componentSchema in fieldSchema.components {
            if componentSchema.discriminator {
                if componentSchema.subcomponents.length() > 0 {
                    return error Error(string `Discriminators on components with subcomponents must be declared on the subcomponent holding the value.
                        Segment: ${segSchema.tag}, Component: ${componentSchema.tag}`);
                }
                check requireValues(componentSchema.values, segSchema.tag, componentSchema.tag);
            }
            foreach EdiSubcomponentSchema subcomponentSchema in componentSchema.subcomponents {
                if subcomponentSchema.discriminator {
                    check requireValues(subcomponentSchema.values, segSchema.tag, subcomponentSchema.tag);
                }
            }
        }
    }
}

isolated function requireValues(string[]? values, string segTag, string nodeTag) returns Error? {
    if values is () || values.length() == 0 {
        return error Error(string `Discriminator nodes must declare a non-empty "values" set.
            Segment: ${segTag}, Element: ${nodeTag}`);
    }
}

// Warns when sibling definitions sharing a segment code cannot be reliably told apart:
// either a sibling has no discriminator (first-in-order matching applies), or two siblings
// allow the same discriminator value (the earlier definition silently wins).
isolated function lintSameCodeSiblings(EdiUnitSchema[] units) {
    map<EdiSegSchema[]> segmentsByCode = {};
    foreach EdiUnitSchema unit in units {
        if unit is EdiSegSchema {
            EdiSegSchema[]? siblings = segmentsByCode[unit.code];
            if siblings is EdiSegSchema[] {
                siblings.push(unit);
            } else {
                segmentsByCode[unit.code] = [unit];
            }
        }
    }
    foreach [string, EdiSegSchema[]] [code, siblings] in segmentsByCode.entries() {
        if siblings.length() < 2 {
            continue;
        }
        string[][] signatures = [];
        foreach EdiSegSchema sibling in siblings {
            string[] signature = discriminatorSignature(sibling);
            if signature.length() == 0 {
                log:printWarn(string `Multiple sibling definitions share the segment code "${code}" and the definition "${sibling.tag}" has no discriminator. Input segments are assigned to the first definition in schema order.`);
            }
            signatures.push(signature);
        }
        foreach int i in 0 ..< siblings.length() {
            foreach int j in (i + 1) ..< siblings.length() {
                foreach string entry in signatures[i] {
                    if signatures[j].indexOf(entry, 0) !is () {
                        log:printWarn(string `Sibling definitions "${siblings[i].tag}" and "${siblings[j].tag}" of segment code "${code}" allow the same discriminator value (${entry}). The earlier definition in schema order wins.`);
                        break;
                    }
                }
            }
        }
    }
}

// Builds a set of "position=value" entries for every discriminator value a segment accepts.
isolated function discriminatorSignature(EdiSegSchema segSchema) returns string[] {
    string[] signature = [];
    foreach int i in 0 ..< segSchema.fields.length() {
        EdiFieldSchema fieldSchema = segSchema.fields[i];
        if fieldSchema.discriminator {
            string[]? values = fieldSchema.values;
            if values is string[] {
                foreach string value in values {
                    signature.push(string `${i}=${value}`);
                }
            }
        }
        foreach int j in 0 ..< fieldSchema.components.length() {
            EdiComponentSchema componentSchema = fieldSchema.components[j];
            if componentSchema.discriminator {
                string[]? values = componentSchema.values;
                if values is string[] {
                    foreach string value in values {
                        signature.push(string `${i}.${j}=${value}`);
                    }
                }
            }
            foreach int k in 0 ..< componentSchema.subcomponents.length() {
                EdiSubcomponentSchema subcomponentSchema = componentSchema.subcomponents[k];
                if subcomponentSchema.discriminator {
                    string[]? values = subcomponentSchema.values;
                    if values is string[] {
                        foreach string value in values {
                            signature.push(string `${i}.${j}.${k}=${value}`);
                        }
                    }
                }
            }
        }
    }
    return signature;
}
