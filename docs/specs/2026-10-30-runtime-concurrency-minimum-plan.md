# Concurrencia segura: plan mínimo

Estado: implementación del primer incremento; aceptación completa pendiente.

- Base: `origin/main`, `224e2eda6a3f3e8f3a952869e41078d66a0b1477`, incluye #571.
- Rama: `alvaro/runtime-concurrency-minimal`.
- Worktree: `/Users/alvaro/.codex/worktrees/runtime-concurrency-minimal/astra`.
- El candidato anterior permanece conservado en `alvaro/runtime-shared-state`.
- No se trasladan cambios del candidato anterior.

La evidencia y las limitaciones actuales están en
[runtime-concurrency-minimum.md](../testing/runtime-concurrency-minimum.md).
El primer defecto reproducido es la reutilización de una sesión nativa desde una
copia importada mientras el dueño original conserva herramientas inciertas.
La corrección utiliza el mismo journal y broker; no añade una reserva por cuenta.

## Resultado que necesitamos

Dos tareas de la misma cuenta y proveedor pueden trabajar simultáneamente cuando sus sesiones y recursos son independientes. Detener una no interrumpe la otra. Una sesión compartida impide ejecuciones competidoras. Retry, recuperación y reinicio de ASTRA preservan un único dueño, el contexto y los límites restantes de la solicitud.

El primer entregable será un flujo completo demostrado en ASTRA Dev con Codex y la corrección mínima de cualquier fallo reproducido. Si ese flujo ya funciona en `main`, se conserva y se documenta: no se reescribe. El objetivo final sigue abarcando los seis runtimes, mediante incrementos verificables y acotados.

## Garantías que no se negocian

- Inspeccionar la ejecución existente antes de iniciar otra; mantener o reconectar la sesión cuando el proveedor realmente lo permita.
- Reutilizar `RuntimeExecutionOwner`, sus registros y la admisión de recursos existentes. No introducir otro dueño mutable de la misma ejecución.
- Reservar los recursos que la ejecución realmente utiliza. Compartir cuenta no justifica por sí solo una reserva exclusiva durante toda la tarea.
- Un temporizador, una conclusión del modelo o la salida del proceso principal no prueban que sus herramientas hayan terminado.
- La incertidumbre conserva la sesión y los recursos afectados. Si no se puede determinar su alcance, se registra como bloqueo; no se inventa independencia ni se amplía silenciosamente a toda la instalación.
- Autenticación, renovación de credenciales y escrituras compartidas deben conservar protección. No copiar tokens por tarea ni acortar reservas suponiendo que el CLI solo escribe al arrancar.
- La app explica qué recurso espera, quién lo ocupa y qué comprobación falta.
- Una prueba bloqueada por acceso no equivale a una prueba superada. No debilitar verificaciones ni desactivar capacidades para conseguir verde.

## Pasos y condiciones de avance

### 1. Leer la base y delimitar el fallo antes de modificar código

Revisar los tests existentes y seguir la adquisición, persistencia y liberación de reservas. Preparar un inventario breve por proveedor: recurso, dueño, duración, quién lo modifica y evidencia necesaria para liberarlo.

| Recurso | Pregunta que debe responder la revisión |
| --- | --- |
| Workspace | ¿Se reserva la identidad física correcta y únicamente donde hay acceso incompatible? |
| Sesión nativa | ¿Dos tareas, copias importadas o procesos de ASTRA pueden ejecutar la misma sesión? |
| Configuración | ¿ASTRA o el CLI la modifican? ¿El proveedor permite configuración independiente sin duplicar credenciales? |
| Credenciales | ¿Hay renovación automática durante la tarea? ¿Qué coordinación real ofrece ese proveedor? |
| Autenticación | ¿Qué proceso escribe credenciales y qué trabajos entrarían en conflicto con esa escritura? |

Puntos de partida ya presentes en esta base:

- `Astra/Services/Runtime/RuntimeExecutionOwner.swift` y su almacén: dueño, admisión, Retry y límites.
- `AgentRuntimeSharedStateGate.swift`, `RuntimeProviderResourceRegistry.swift` y `AgentRuntimeAdapter.swift`: configuración compartida y límites por adaptador.
- `Tests/RuntimeRecoveryOwnershipTests.swift`, `Tests/RuntimeRecoveryProcessTests.swift`, `Tests/ProviderSharedStateLaunchTests.swift`, `Tests/ProviderSharedStateMigrationTests.swift` y `Tests/RuntimeProviderResourceBlockTests.swift`.
- `docs/testing/runtime-cancellation-matrix.md`: evidencia histórica y límites; no sustituye nuevas pruebas de concurrencia.
- #571 trata recuperación del registro de credenciales de conectores; preservar esas garantías sin convertir este trabajo en otra migración de credenciales.

Salida: mapa de reservas y una hipótesis concreta de fallo, o ausencia de fallo observado. No crear un sistema universal de recursos antes de obtener esta evidencia.

### 2. Demostrar primero un flujo completo con Codex en la app

Usar ASTRA Dev con almacén y workspaces sintéticos aislados. Las tareas A y B usarán la misma cuenta y el mismo perfil de proveedor, con sesiones nativas y workspaces distintos. No usar producción ni sustituir esta prueba por dos perfiles.

Registrar antes de empezar: commit, versión del CLI, identidad de cuenta sin secretos, permisos, presupuesto y límites de espera. Mantener las capacidades habituales; incluir trabajo local acotado con herramientas reales, no solamente respuestas de texto.

1. Iniciar A y B y demostrar que ambas progresan durante un intervalo común. Capturar los identificadores de ejecución/sesión y evidencia de actividad de las dos; dos etiquetas «Running» no bastan.
2. Pulsar Stop en A. B debe seguir progresando y terminar sin reinicio, pérdida de contexto ni bloqueo causado por A. Distinguir «detención solicitada» de «detención confirmada».
3. Intentar ejecutar una misma sesión desde dos tareas. Solo una puede lanzarse; la otra debe explicar la espera. Identificar si esta variante necesita una fixture controlada además de interacción con la app.
4. Competir con Retry y recuperación, y reiniciar ASTRA. Verificar que no aparecen dos ejecuciones de la misma sesión y que se conservan dueño, contexto y límites restantes.
5. Retener o perder una señal final mediante inyección de fallo identificada. Mantener protegidos los recursos afectados mientras una tarea independiente continúa. No fabricar pruebas de detención.
6. Confirmar que dos proveedores distintos que necesitan acceso incompatible al mismo workspace esperan correctamente y que un sucesor se inicia una sola vez tras una liberación válida.

Salida: evidencia reproducible de cada caso, o el primer bloqueo concreto. Si una renovación de credenciales o una herramienta sin cierre verificable impide el flujo, explicarlo antes de diseñar cambios.

### 3. Corregir solo una causa raíz demostrada

Añadir primero una regresión significativa para el defecto observado. Reutilizar los dueños y servicios existentes; cambiar únicamente la condición, el recurso o la integración del proveedor que causa el conflicto.

Ejemplo de solución admisible: dejar de sobrescribir una configuración compartida usando una opción nativa verificada para configuración independiente, sin copiar credenciales. No asumir de antemano que todos los proveedores ofrecen esa opción.

Si el CLI puede renovar tokens o modificar archivos durante toda la ejecución, un bloqueo breve al inicio no basta. Obtener evidencia de su coordinación nativa o declarar el bloqueo. La misma regla aplica a herramientas locales separadas y trabajo remoto cuyo final no se pueda demostrar.

Salida: una corrección pequeña con regresión, o una decisión pendiente con problema, evidencia y alternativa mínima. No incorporar un ejecutor universal para resolver automáticamente ese bloqueo.

### 4. Cerrar el primer proveedor antes de extender el cambio

Repetir el flujo completo del paso 2 sobre el candidato corregido. Recoger resultados terminales, conteos de lanzamientos, dueño persistente, límites y mensajes visibles. Separar pruebas automatizadas, controles de backend y acciones reales en la app.

El primer incremento se acepta cuando los seis escenarios pasan para el proveedor probado y no se debilitan los demás. Si `main` ya los supera, el entregable puede ser la evidencia y una regresión que cubra una carencia real; no crear cambios de producción innecesarios.

Un incremento acotado puede revisarse por separado. La capacidad de concurrencia de los seis proveedores no se declara completa hasta terminar toda la matriz.

### 5. Extender la misma aceptación a los otros proveedores, uno a uno

No generalizar desde Codex. Revisar las señales y escrituras de cada CLI y aplicar los pasos 2 a 4. Compartir cuenta y perfil dentro de cada prueba sigue siendo obligatorio.

| Proveedor | Pruebas automatizadas en esta base | Concurrencia real en ASTRA Dev | Acceso actual |
| --- | --- | --- | --- |
| Codex CLI | Pendiente | Pendiente; primero | Por comprobar |
| Claude Code | Pendiente | Pendiente | Por comprobar |
| Google Antigravity CLI | Pendiente | Pendiente | Por comprobar |
| GitHub Copilot CLI | Pendiente | Pendiente | Por comprobar |
| Cursor CLI | Pendiente | Pendiente | Por comprobar |
| OpenCode CLI | Pendiente | Pendiente | Por comprobar |

Las limitaciones antiguas de cuota o autenticación no se asumen vigentes. Si reaparecen, se documentan y se detiene esa prueba: no se rediseña el inicio de sesión ni se repiten intentos indefinidamente.

### 6. Revisar y validar el candidato consolidado

Solicitar revisión con un subagente limitada a garantías, regresiones y alcance. Corregir sus hallazgos relacionados y consolidar el candidato en un commit pasando los hooks existentes, sin omitirlos.

Validar el commit final con pruebas relevantes, suite completa, build verificado de desarrollo, QA aislado aplicable, hooks y CI. Comandos de referencia del repositorio:

```bash
script/swift_test.sh --filter <SuiteRelevante> --jobs 2 --no-parallel
script/swift_test.sh --no-parallel --jobs 2
./script/build_and_run.sh bundle
git diff --check
```

El modo `bundle` ya verifica el paquete sin abrir el almacén habitual de desarrollo. La comprobación de arranque y los flujos se harán con una instancia de ASTRA Dev explícitamente aislada. Verificar que el binario probado corresponde al commit final; no contar un build anterior como aceptación del nuevo código.

Ejecutar una sola tanda de pruebas a la vez, con logs y límite de diagnóstico definido antes. Si deja de progresar, capturar el estado, detenerla con seguridad e investigar ese caso. Un timeout del harness significa prueba incompleta; nunca autoriza liberar una reserva de producto. No comparar fallos de tandas o commits distintos como evidencia de mejora.

Si el candidato cambia tras validar, repetir las comprobaciones afectadas y cerrar la suite completa y CI sobre el nuevo commit final. Presentar resultados, evidencia y siguiente bloqueo en cada hito. Mantener la PR en draft mientras falten pruebas de seguridad o paralelismo dentro del alcance declarado; no hacer merge.

## Límites explícitos

No incluir por defecto: ejecutor universal de herramientas, rediseño de autenticación de los seis proveedores, copia/sincronización de tokens, cambios de ADC, Docker o SSH, migración global de registros históricos, nueva recuperación agresiva, limpieza de datos del usuario ni rediseño de UI.

Esto no autoriza ignorar un fallo necesario para las garantías. Si resolverlo exige uno de esos cambios, detener esa ampliación y presentar el bloqueo y la solución mínima antes de continuar. Conservar las reservas reales y las pruebas existentes.

La implementación fue autorizada. El QA inicial de Codex demuestra actividad
simultánea y protección frente a Retry/reinicio, pero no acredita cierre de
herramientas al pulsar Stop ni aceptación de los seis proveedores. La PR debe
permanecer en draft mientras esas garantías sigan sin demostrarse.
