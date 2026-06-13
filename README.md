# Urban Environmental Monitoring workspace

Questo archivio contiene due repository indipendenti:

1. `urban-environmental-data-generator`: generazione offline una tantum;
2. `urban-environmental-monitoring`: sistema runtime minimale.

Seguire `urban-environmental-monitoring/docs/setup/step_by_step.md`.
Il runtime usa checkpoint Makefile (`bootstrap-core`, `bootstrap-data`, `bootstrap-live`, `status`) per rendere il setup ripetibile.
