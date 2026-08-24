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

import ballerina/io;
import ballerina/test;

@test:Config
function testFieldDiscriminatorsWithoutOptionalSegment() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/x12-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    string ediText = check io:fileReadString("tests/resources/value-discriminators/x12_without_policy.edi");
    json result = check fromEdiString(ediText, schema);
    map<json> resultMap = check result.cloneWithType();

    test:assertFalse(resultMap.hasKey("MemberPolicyNumber"),
        "REF*17 must not be assigned to the optional member policy definition");
    test:assertEquals(check result.SubscriberIdentifier.qualifier, "0F");
    json supplemental = check result.MemberSupplementalIdentifier;
    test:assertTrue(supplemental is json[]);
    json[] supplementalIdentifiers = <json[]>supplemental;
    test:assertEquals(supplementalIdentifiers.length(), 2);
    test:assertEquals(check supplementalIdentifiers[0].qualifier, "17");
    test:assertEquals(check supplementalIdentifiers[1].qualifier, "DX");
}

@test:Config
function testFieldDiscriminatorsWithOptionalSegment() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/x12-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    string ediText = check io:fileReadString("tests/resources/value-discriminators/x12_with_policy.edi");
    json result = check fromEdiString(ediText, schema);

    test:assertEquals(check result.SubscriberIdentifier.qualifier, "0F");
    test:assertEquals(check result.MemberPolicyNumber.qualifier, "1L");
    test:assertEquals(check result.MemberPolicyNumber.identifier, "373");
    json supplemental = check result.MemberSupplementalIdentifier;
    test:assertTrue(supplemental is json[]);
    json[] supplementalIdentifiers = <json[]>supplemental;
    test:assertEquals(supplementalIdentifiers.length(), 3);
    test:assertEquals(check supplementalIdentifiers[0].qualifier, "17");
    test:assertEquals(check supplementalIdentifiers[1].qualifier, "23");
    test:assertEquals(check supplementalIdentifiers[2].qualifier, "DX");
}

@test:Config
function testComponentDiscriminatorsWithSpecializedDefinitions() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/edifact-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    string ediText = check io:fileReadString("tests/resources/value-discriminators/edifact_message.edi");
    json result = check fromEdiString(ediText, schema);

    test:assertEquals(check result.SellersReference.REFERENCE.qualifier, "SS");
    test:assertEquals(check result.SellersReference.REFERENCE.number, "1111-000000");
    test:assertEquals(check result.VatNumber.REFERENCE.qualifier, "VA");
    test:assertEquals(check result.VatNumber.REFERENCE.number, "SE556421030901");
}

@test:Config
function testComponentDiscriminatorsSkipAbsentOptionalDefinition() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/edifact-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    string ediText = check io:fileReadString("tests/resources/value-discriminators/edifact_vat_only.edi");
    json result = check fromEdiString(ediText, schema);
    map<json> resultMap = check result.cloneWithType();

    test:assertFalse(resultMap.hasKey("SellersReference"),
        "RFF+VA must not be assigned to the sellers reference definition");
    test:assertEquals(check result.VatNumber.REFERENCE.qualifier, "VA");
}

@test:Config
function testEmptyDiscriminatorValueDoesNotMatchAnyDefinition() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/x12-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    string ediText = "INS*Y*18~\nREF*0F*110011113~\nREF**Bargained~";
    json|Error result = fromEdiString(ediText, schema);
    test:assertTrue(result is Error,
        "A segment with an empty discriminator value must not be assigned to any discriminated definition");
}

@test:Config
function testUnknownDiscriminatorValueDoesNotMatchAnyDefinition() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/x12-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    string ediText = "INS*Y*18~\nREF*0F*110011113~\nREF*99*SOMETHING~";
    json|Error result = fromEdiString(ediText, schema);
    test:assertTrue(result is Error,
        "A segment with a qualifier outside every definition's value set must not be silently assigned");
}

@test:Config
function testWriterRejectsValueOutsideAllowedSet() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/x12-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    json invalidMessage = {
        MemberLevelDetail: {code: "INS", memberIndicator: "Y", relationship: "18"},
        SubscriberIdentifier: {code: "REF", qualifier: "0F", identifier: "110011113"},
        MemberPolicyNumber: {code: "REF", qualifier: "17", identifier: "Bargained"}
    };
    string|Error result = toEdiString(invalidMessage, schema);
    test:assertTrue(result is Error, "The writer must reject qualifier 17 for MemberPolicyNumber");
}

@test:Config
function testWriterAcceptsValuesInAllowedSet() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/x12-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    json message = {
        MemberLevelDetail: {code: "INS", memberIndicator: "Y", relationship: "18"},
        SubscriberIdentifier: {code: "REF", qualifier: "0F", identifier: "110011113"},
        MemberPolicyNumber: {code: "REF", qualifier: "1L", identifier: "373"}
    };
    string ediText = check toEdiString(message, schema);
    test:assertTrue(ediText.includes("REF*1L*373~"), "Valid policy number segment must be serialized");
}

@test:Config
function testWriterRejectsComponentValueOutsideAllowedSet() returns error? {
    json schemaJson = check io:fileReadJson("tests/resources/value-discriminators/edifact-schema.json");
    EdiSchema schema = check getSchema(schemaJson);
    json invalidMessage = {
        BeginningOfMessage: {code: "BGM", documentName: "82"},
        VatNumber: {code: "RFF", REFERENCE: {qualifier: "SS", number: "SE556421030901"}}
    };
    string|Error result = toEdiString(invalidMessage, schema);
    test:assertTrue(result is Error, "The writer must reject qualifier SS for the VAT number definition");
}

@test:Config
function testDiscriminatorWithoutValuesIsRejectedAtLoadTime() returns error? {
    json schemaJson = {
        "name": "InvalidDiscriminatorTest",
        "delimiters": {"segment": "~", "field": "*", "component": ":"},
        "segments": [
            {
                "code": "REF",
                "tag": "Reference",
                "fields": [{"tag": "code"}, {"tag": "qualifier", "discriminator": true}]
            }
        ]
    };
    EdiSchema|error schema = getSchema(schemaJson);
    test:assertTrue(schema is error, "Discriminators without a values set must be rejected at schema load time");
}

@test:Config
function testDiscriminatorOnRepeatingFieldIsRejectedAtLoadTime() returns error? {
    json schemaJson = {
        "name": "InvalidRepeatDiscriminatorTest",
        "delimiters": {"segment": "~", "field": "*", "component": ":"},
        "segments": [
            {
                "code": "REF",
                "tag": "Reference",
                "fields": [
                    {"tag": "code"},
                    {"tag": "qualifier", "repeat": true, "values": ["1L"], "discriminator": true}
                ]
            }
        ]
    };
    EdiSchema|error schema = getSchema(schemaJson);
    test:assertTrue(schema is error, "Discriminators on repeating fields must be rejected at schema load time");
}

@test:Config
function testDiscriminatorOnCompositeFieldIsRejectedAtLoadTime() returns error? {
    json schemaJson = {
        "name": "InvalidCompositeDiscriminatorTest",
        "delimiters": {"segment": "~", "field": "*", "component": ":"},
        "segments": [
            {
                "code": "RFF",
                "tag": "Reference",
                "fields": [
                    {"tag": "code"},
                    {
                        "tag": "REFERENCE",
                        "values": ["VA"],
                        "discriminator": true,
                        "components": [{"tag": "qualifier"}, {"tag": "number"}]
                    }
                ]
            }
        ]
    };
    EdiSchema|error schema = getSchema(schemaJson);
    test:assertTrue(schema is error,
        "Discriminators on composite fields must be declared on the component holding the value");
}
