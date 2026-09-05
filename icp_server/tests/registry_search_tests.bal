// Copyright (c) 2026, WSO2 LLC. All Rights Reserved.

import ballerina/test;

import icp_server.mi_management;
import icp_server.types;

// Registry search validates the input before contacting a runtime. This keeps
// accidental empty searches from producing an expensive recursive MI request.
@test:Config {
    groups: ["registry-search-graphql"]
}
function testRegistryResourceSearchRequiresSearchKey() returns error? {
    string query = string `
        query {
            registryResourceSearch(
                runtimeId: "00000000-0000-0000-0000-000000000003",
                path: "registry/config",
                searchKey: "   "
            ) {
                count
                items { name path mediaType isDirectory }
            }
        }
    `;

    json response = check executeGraphQL(query, orgDevToken);
    test:assertTrue(response.errors is json, "An empty search key should return a GraphQL error");
    json[] errors = check response.errors.ensureType();
    test:assertTrue(errors.length() > 0, "The response should include a validation error");
    string message = check (check errors[0].message).ensureType();
    test:assertTrue(message.includes("Search key is required"), string `Unexpected error: ${message}`);
}

@test:Config {
    groups: ["registry-search-graphql"]
}
function testRegistrySearchFlattensNestedPaths() {
    json tree = {
        name: "config",
        'type: "directory",
        files: [
            {name: "nested", 'type: "directory", files: [
                {name: "settings.json", 'type: "application/json", files: []}
            ]},
            {name: "other.txt", 'type: "text/plain", files: []}
        ]
    };

    types:RegistrySearchItem[] results = mi_management:flattenRegistrySearchNode(tree, "registry", "settings");
    test:assertEquals(results.length(), 1);
    test:assertEquals(results[0].name, "settings.json");
    test:assertEquals(results[0].path, "registry/config/nested/settings.json");
    test:assertEquals(results[0].mediaType, "application/json");
    test:assertFalse(results[0].isDirectory);
}
