# AI-powered Ballerina Connector Automation

This project automates Ballerina connector generation from Java SDKs using a multi-stage AI-assisted pipeline.

It supports:
- Java SDK + Javadoc analysis
- Metadata extraction and normalization
- AI-assisted API spec generation
- Connector source generation (Ballerina + Java native adaptor)
- Iterative post-generation code fixing for native Java adaptor issues

## What this repository does

Given a dataset key (for example `s3-2.4.0`), the toolchain resolves SDK artifacts from `test-jars/`, analyzes SDK classes, generates intermediate representations, and emits connector code.

End-to-end pipeline:
1. Analyze Java SDK (`modules/sdkanalyzer`)
2. Generate IR + Ballerina spec (`modules/api_specification_generator`)
3. Generate connector implementation (`modules/connector_generator`)
4. Optionally fix native Java adaptor compilation issues (`modules/code_fixer`)

## Repository modules

- `modules/sdkanalyzer/` — Java SDK analyzer, type resolution, metadata generation, and LLM-assisted scoring helpers
- `modules/api_specification_generator/` — Builds IR and Ballerina API specification from metadata
- `modules/connector_generator/` — Generates connector source files (`client.bal`, `types.bal`, Java native adaptor)
- `modules/code_fixer/` — Iterative fixer for generated Java native adaptor code
- `main.bal` — CLI entrypoint that orchestrates all stages

## Prerequisites

- Ballerina Swan Lake (`2201.13.1` or compatible with `Ballerina.toml`)
- Java 21 (required by platform dependencies)
- Optional: `ANTHROPIC_API_KEY` for enhanced LLM-powered ranking/scoring paths

## Build

```bash
bal build
```

## CLI commands

```bash
bal run -- analyze <dataset-key> [options]
bal run -- generate <dataset-key> [options]
bal run -- connector <dataset-key> [options]
bal run -- fix-code <dataset-key> [options]
bal run -- fix-report-only <dataset-key> [options]
bal run -- pipeline <dataset-key> [options]
```

Example:

```bash
bal run -- pipeline s3-2.4.0 --fix-code
```

## Dataset key resolution

- SDK JAR: `test-jars/<dataset-key>.jar`
- Javadoc JAR: `test-jars/<dataset-key>-javadoc.jar`

## Generated artifacts

- Metadata: `modules/sdkanalyzer/output/<dataset-key>-metadata.json`
- IR: `modules/api_specification_generator/IR-output/<dataset-key>-ir.json`
- Spec: `modules/api_specification_generator/spec-output/<dataset-key>_spec.bal`
- Connector Ballerina sources: `modules/connector_generator/output/ballerina/`
- Connector Java native adaptor: `modules/connector_generator/output/src/main/java/`

## Notes

- Generated Java native adaptor code depends on Ballerina runtime and SDK libraries; unresolved imports in editors are expected without full classpath setup.
- Generated Gradle files in connector output are intended to make native adaptor dependency resolution deterministic.

## Current focus

This codebase is actively developed for **AI-powered automation of Ballerina connector generation from Java SDKs**, with emphasis on reducing manual effort across analysis, spec creation, and connector implementation.
