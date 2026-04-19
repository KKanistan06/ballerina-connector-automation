string backtick = "`";
string tripleBacktick = "```";

function createTestGenerationPrompt(ConnectorAnalysis analysis) returns string {
    string methodTypeGuidance = "";
    string methodSignaturesSection = "";

    if analysis.methodType == "remote" {
        methodTypeGuidance = string `
**CRITICAL - Remote Method Syntax:**
This connector uses REMOTE methods, NOT resource methods. You MUST use the following syntax:
- Correct: ${backtick}Type response = check client->methodName(param1, param2);${backtick}
- WRONG: ${backtick}Type response = check client->/path/to/resource();${backtick}

The method signatures are provided in <REMOTE_METHOD_SIGNATURES>. Use these exact method names and parameters.
`;

        methodSignaturesSection = string `
      <REMOTE_METHOD_SIGNATURES>
        ${analysis.remoteMethodSignatures}
      </REMOTE_METHOD_SIGNATURES>
`;
    } else {
        methodTypeGuidance = string `
This connector uses resource methods. Use the resource path syntax from the mock server.
`;
    }

    string enumSection = "";
    if analysis.enumDefinitions.length() > 0 {
        enumSection = string `
      <ENUM_DEFINITIONS>
        ${analysis.enumDefinitions}
      </ENUM_DEFINITIONS>
`;
    }

    return string `
    You are an expert Ballerina developer specializing in robust, production-quality LIVE integration tests for connectors. Your task is to generate a complete ${backtick}test.bal${backtick} file for the provided connector.

    **Phase 1: Reflection (Internal Monologue)**

    Before generating any code, I must reflect on the key requirements for a perfect test file.
    1.  **Output Purity:** The final output must be a single, complete, raw Ballerina source code file. No conversational text, no explanations, no apologies, and absolutely no markdown formatting like ${tripleBacktick}ballerina.
    2.  **Client Initialization: This is the most critical and complex part.** The user has provided the exact ${backtick}<CLIENT_INIT_METHOD>${backtick} signature and the necessary ${backtick}<REFERENCED_TYPE_DEFINITIONS>${backtick}. I must meticulously use this information to construct the client initialization code. I cannot use a generic template; it must be tailored precisely to the provided context to avoid compilation errors.
    ${methodTypeGuidance}
    3.  **Environment Configuration (LIVE ONLY):**
        * There is NO mock server in this project.
        * Tests must run against live endpoints using the generated Ballerina client.
        * Create runtime gating using environment variables. If required credentials are missing, each test should return early (skip behavior) without failing compilation.
        * Infer required env var names from the ConnectionConfig fields (e.g. access key, secret, region, endpoint override). Do NOT hard-code any vendor-specific env var names; derive them from the connector's own configuration types.
    4.  **Test Function Logic & Assertions:** My goal is to verify API behavior, response shape, and error handling for live calls.
        * **Coverage target:** Generate AT LEAST one primary happy-path test for EVERY client operation listed in the signatures/paths. Then add additional edge-case and use-case tests for operations that accept optional parameters, produce different result shapes, or involve state transitions (create→use→delete). The total test count should comfortably exceed the number of client operations.
        * A common pitfall to avoid is using direct HTTP return types like ${backtick}http:Accepted${backtick}. If a successful response has no body, the function should assign the result to ${backtick}error?${backtick} and the test's purpose is to ensure no error is returned.
        * Every test function MUST include assertions to validate the response.
        * NEVER write tautological assertions that can become always-true hints (e.g., ${backtick}(value is string) && (<string>value).length() > 0${backtick} after non-nil checks).
        * NEVER write assertions that are logically always true, such as:
          - ${backtick}test:assertTrue(x !is () || x is (), ...);${backtick}
          - ${backtick}test:assertTrue(response is SomeResponseType, ...);${backtick} when ${backtick}response${backtick} is already declared as ${backtick}SomeResponseType${backtick}
        * For optional fields, write meaningful checks only when appropriate:
          - If field may legally be absent, DO NOT assert type compatibility using unions like ${backtick}value is T || value is ()${backtick} (this is redundant and triggers compiler hints).
          - Instead, assert behavior only in the non-nil branch (e.g., ${backtick}if value is T { test:assertTrue(...); }${backtick}) and otherwise skip optional-field assertions.
          - If field is required for the operation's success path, assert non-empty/non-nil value directly.
        * Prefer assertions like ${backtick}test:assertTrue((value ?: "").length() > 0, ...);${backtick}.
        * **Live API Behavior Expectations (CRITICAL):**
          - Optional fields in live API responses are often nil/empty when not populated, even on successful calls
          - Array results may be completely empty (zero items) when no data matches the query
          - Collections (lists, arrays) may return nil instead of empty array structure
          - Previously created resources may still exist from earlier test runs; assertions must tolerate this
          - Assertions should validate required fields or successful behavior, not redundant static type checks
        * **Assertion Strategy:**
            * For responses that return a single record (object), do NOT assert ${backtick}response is ResponseType${backtick} when ${backtick}response${backtick} is already declared as that type.
            * For optional fields within that response, only assert if they are required for the operation to succeed; do NOT assert optional fields are non-nil
            * For responses that return arrays or list fields, prefer checks on length/required content only when semantically required by the operation.
            * Where applicable, also assert that the ${backtick}errors${backtick} field is nil: ${backtick}test:assertTrue(response?.errors is ());${backtick}.
            * Avoid any assertion that the compiler can prove always true at compile time.
    5.  **Completeness and Correctness:** I must ensure all necessary imports (${backtick}ballerina/os${backtick}, ${backtick}ballerina/test${backtick}, etc.) are present and that the entire file is syntactically correct and ready to compile.

    **Phase 2: Execution**

    Based on my reflection, I will now generate the complete ${backtick}test.bal${backtick} file with extreme precision.

    <CONTEXT>
      <PACKAGE_NAME>
        ${analysis.packageName}
      </PACKAGE_NAME>
      <CLIENT_INIT_METHOD>
        ${analysis.initMethodSignature}
      </CLIENT_INIT_METHOD>
      <REFERENCED_TYPE_DEFINITIONS>
        ${analysis.referencedTypeDefinitions}
      </REFERENCED_TYPE_DEFINITIONS>
      <CONNECTION_CONFIG_DEFINITION>
        ${analysis.connectionConfigDefinition}
      </CONNECTION_CONFIG_DEFINITION>
${enumSection}${methodSignaturesSection}
    </CONTEXT>

    **Requirements:**
    1.  **Complete File:** Your response must be a single, raw, and complete Ballerina source code file. Do not include any code fences in the response.
    2.  **Copyright Header:** The generated file must start with the standard Ballerina copyright header.
    3.  **Imports:** Include ${backtick}import ballerina/os;${backtick}, ${backtick}import ballerina/test;${backtick}, and connector imports only. Do NOT import any mock server module.
    4.  **Environment Setup:** Build client configuration from environment variables for live execution. Implement helper functions like ${backtick}isLiveTestEnabled()${backtick} and ${backtick}getClient()${backtick}. Use endpoint override env var when present.
        - Use a sentinel error prefix exactly: ${backtick}LIVE_TEST_DISABLED:${backtick}
        - If required env vars are missing, return ${backtick}error("LIVE_TEST_DISABLED: ...")${backtick}.
        - If runtime/client creation panics or returns an error for other reasons, return that error (test must fail, not silently pass).
    5.  **Correct Client Initialization:** You MUST use the provided ${backtick}<CLIENT_INIT_METHOD>${backtick} and ${backtick}<REFERENCED_TYPE_DEFINITIONS>${backtick} to correctly initialize the client.
    6.  **Full Test Coverage:** Generate test functions for ALL client operations present in the provided signatures. Do not skip any operation. For operations that accept optional parameters or involve state transitions, add additional edge-case tests so total tests comfortably exceed the operation count.
    7.  **Correct Method Invocation Syntax:** ${analysis.methodType == "remote" ? "Use REMOTE method syntax (->methodName())" : "Use resource method syntax (->/path)"}.
    8.  **Smart Assertions:** Each test must contain assertions.
    9.  **Proper Return Types:** For functions that return a non-record success response (e.g., HTTP 202 Accepted), the test variable should be of type ${backtick}error?${backtick}.
    10. **Advanced, Correct Assertions:**
        * For functions returning ${backtick}error?${backtick}, **you must use ${backtick}test:assertTrue(response is (), "...");${backtick}**. Crucially, **DO NOT use ${backtick}test:assertNil${backtick}**.
        * Apply the nuanced assertion strategy for records: check array length for arrays, check ${backtick}!is ()${backtick} for optional records, and check a nested field for mandatory records.
      * Never generate redundant assertions like ${backtick}test:assertTrue(response is SomeType, ...);${backtick} when ${backtick}response${backtick} is already statically typed as ${backtick}SomeType${backtick}.
      * Do not create unused local variables; if a return value is intentionally ignored, assign it to ${backtick}_${backtick} (e.g., ${backtick}_ = os:setEnv("KEY", value);${backtick}).
    11. **Strict Enum Usage:** If ${backtick}<ENUM_DEFINITIONS>${backtick} is provided, use enum member names only where the Ballerina parameter type is explicitly an enum type.
        * **CRITICAL - Never use enum members as optional array parameter values** (e.g. do NOT write ${backtick}attributeNames = [SOME_ENUM]${backtick}). If a method has an optional array parameter, simply omit it — call the method without that argument and the API will provide a default response.
        * **CRITICAL - Never use computed enum key syntax in map literals** (e.g. do NOT write ${backtick}{[ENUM_KEY]: "value"}${backtick}). For ${backtick}map<string>${backtick} parameters, always use plain string literal keys matching the API's expected format.
    12. **Resource Name Uniqueness (CRITICAL for Live Testing):** When creating test resources (queues, topics, buckets, entities, etc.), use unique names to differentiate test executions. 
        * Do NOT use hardcoded resource names that conflict on repeated runs
        * Use a pattern like: ${backtick}const string TEST_RESOURCE_NAME = "test_resource_" + check time:uuid();${backtick} or similar unique identifier
        * This prevents "resource already exists" or "name conflict" errors when tests run multiple times against the live API
    13. **Test Groups:** All test functions must be annotated with ${backtick}@test:Config { groups: ["live_tests"] }${backtick}.
    14. **Test Ordering with dependsOn:** Use ${backtick}dependsOn${backtick} ONLY where one test truly requires state created by another (e.g. a "send message" test depends on "create resource"). Do NOT add dependsOn to independent tests.
    15. **Runtime Gating Rule:**
        - At test start, obtain client via helper: ${backtick}Client|error clientResult = getClient();${backtick}
        - If error message starts with ${backtick}LIVE_TEST_DISABLED:${backtick}, return (skip).
        - Otherwise return the error from the test function (fail test).
    16. **Resource Helper:** Provide a helper (e.g. ${backtick}getTestResourceUrl${backtick}) that tries an env-var first, then falls back to creating the resource via the client (idempotent create-or-get pattern) so tests are self-contained without mandatory env setup beyond credentials.
    17. **No Vendor or SDK References:** Do not add any vendor or SDK references in generated comments, test names, assertion messages, or helper descriptions. Keep wording generic and connector-centric. Do NOT mention specific tool names, SDK versions, or vendor product names in code comments.

    Now, generate the complete and final ${backtick}test.bal${backtick} file.
`;
}

function createOperationSelectionPrompt(string[] operationIds, int maxOperations) returns string {
    string operationList = string:'join(", ", ...operationIds);

    return string `
You are an expert API designer. Your task is to select the ${maxOperations} most useful and frequently used operations from the following list of API operations.

**CRITICAL: Your response must be ONLY a comma-separated list of operation IDs with NO spaces between them. This will be used directly in a bal openapi command.**

<OPERATIONS>
${operationList}
</OPERATIONS>

Consider these criteria when selecting operations:
1. **Core CRUD Operations**: Basic create, read, update, delete operations
2. **Most Frequently Used**: Operations that developers typically use first
3. **Representative Coverage**: Cover different resource types available in the API
4. **Search & Discovery**: Include search and listing operations
5. **Lifecycle Operations**: Include setup, teardown, and configuration operations

Select exactly ${maxOperations} operation IDs that provide the most value for developers getting started with this API.

**IMPORTANT: Return ONLY the comma-separated list with no spaces, like this format:**
createResource,getResource,listResources,updateResource,deleteResource,searchResources

Your response:`;
}
