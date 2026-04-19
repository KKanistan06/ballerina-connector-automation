public type ConnectorAnalysis record {
    string packageName;
    string initMethodSignature;
    string referencedTypeDefinitions;
    string connectionConfigDefinition = "";
    string enumDefinitions = "";
    "resource"|"remote" methodType = "resource";
    string remoteMethodSignatures = "";

};
