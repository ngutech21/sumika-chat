# Security Policy

## Supported Versions

Security fixes are provided for the latest release of Sumika. Before reporting
an issue, please confirm that it is still reproducible with the latest version.
Older releases may not receive security updates.

## Reporting a Vulnerability

Please do not disclose suspected vulnerabilities in a public issue, discussion,
or pull request.

Report them privately through
[GitHub Security Advisories](https://github.com/ngutech21/sumika-chat/security/advisories).
Use **Report a vulnerability** on that page and include, where possible:

- A clear description of the vulnerability and its potential impact.
- The affected Sumika version, macOS version, and relevant configuration.
- Reproduction steps or a minimal proof of concept.
- Any known prerequisites, workarounds, or mitigations.
- Whether you have disclosed the issue anywhere else.

Remove passwords, API keys, private conversations, personal data, and other
unrelated sensitive information from reports and attachments.

The maintainers will review the report, may ask for additional information, and
will coordinate remediation and disclosure through the private advisory. Please
allow a reasonable amount of time for investigation and for affected users to
receive a fix before publishing details.

## Scope

Examples of issues that should be reported privately include:

- Bypasses of approval, workspace, sandbox, or tool-permission boundaries.
- Unauthorized file access, command execution, or disclosure of local data.
- Vulnerabilities in model, MCP, web, persistence, update, or installation
  workflows that cross an intended security boundary.
- Exposed credentials or sensitive information attributable to Sumika.
- Vulnerable dependencies that are exploitable through Sumika.

Unexpected or unsafe model output by itself is not necessarily a security
vulnerability. Please use the public
[issue tracker](https://github.com/ngutech21/sumika-chat/issues) for ordinary
bugs, feature requests, and model-quality problems that do not cross a security
boundary.

## Research Guidelines

When investigating a potential vulnerability:

- Test only on systems and data you own or are authorized to use.
- Minimize access to data and stop once you have enough evidence to report the
  issue.
- Do not degrade services, destroy data, distribute malware, or use social
  engineering.
- Keep vulnerability details confidential until disclosure has been coordinated
  with the maintainers.

The project does not currently offer a bug bounty or guarantee compensation for
reports. Credit may be given in a published advisory when requested and
appropriate.
