# План разработки Neovim-плагина для Jupyter notebooks

Дата исследования: 23 сентября 2026 года.

## 1. Цель проекта

Создать интегрированный в Neovim редактор Jupyter notebooks (`.ipynb`) со следующими возможностями:

- представление notebook как последовательности code, Markdown и raw cells;
- удобное редактирование и структурная навигация по ячейкам;
- корректная работа LSP с кодом во всех code cells;
- выполнение текущей ячейки;
- выполнение всех предыдущих ячеек;
- выполнение всех последующих ячеек;
- выполнение всех ячеек;
- управление Jupyter kernel;
- встроенный вывод текста, ошибок, таблиц и rich MIME;
- вывод статических изображений и matplotlib-графиков через возможности терминала;
- интерактивные Plotly и Bokeh-графики без отдельного browser window;
- сохранение notebook, metadata и outputs без потерь;
- хорошая совместимость с Kitty и существующим Neovim-конфигом.

Ключевые UX-ориентиры:

- Euporie — рендеринг notebook и rich output в терминале;
- jupynvim — простая cell-centric навигация и понятное визуальное представление;
- обычный Neovim — motions, jumplist, registers, undo/redo, LSP и привычное редактирование.

LSP и notebook-навигация являются обязательной частью первой пригодной к использованию версии, а не поздним дополнением.

---

## 2. Результаты исследования существующих решений

Состояние репозиториев проверялось через GitHub API на дату исследования.

### 2.1. Molten

Репозиторий: <https://github.com/benlubas/molten-nvim>

Сильные стороны:

- выполнение кода через Jupyter kernel;
- асинхронный streaming output;
- virtual text и floating output windows;
- поддержка изображений, LaTeX и rich MIME;
- импорт и экспорт outputs из `.ipynb`;
- относительно зрелый проект и заметная пользовательская база.

Ограничения для данного проекта:

- Molten не является полноценным редактором `.ipynb`;
- не преобразует notebook в собственный notebook UI;
- Plotly рендерится в PNG через Plotly и Kaleido, то есть теряет интерактивность;
- HTML открывается через browser-команду;
- используется Python remote plugin и `pynvim`;
- cell detection и редактирование обычно делегируются Quarto, Jupytext или NotebookNavigator.

### 2.2. Magma

Репозиторий: <https://github.com/dccsillag/magma-nvim>

Magma был основой для Molten, но его активность существенно ниже, а основной современный путь развития находится в Molten. Использовать Magma как архитектурную основу нецелесообразно.

### 2.3. Quarto, Otter и Jupytext

Репозитории:

- <https://github.com/quarto-dev/quarto-nvim>
- <https://github.com/jmbuhr/otter.nvim>
- <https://github.com/GCBallesteros/jupytext.nvim>

Сильные стороны:

- хороший text-first workflow;
- LSP для кода внутри Markdown/Quarto;
- удобная работа с fenced code blocks;
- синхронизация `.ipynb` с текстовыми форматами.

Ограничения:

- основным объектом редактирования становится текстовое представление, а не notebook;
- outputs и metadata не являются центральной частью UI;
- отсутствует цельный notebook compositor;
- для достижения требуемого UX приходится соединять несколько плагинов.

### 2.4. Neopyter

Репозиторий: <https://github.com/SUSTech-data/neopyter>

Сильные стороны:

- синхронизация Neovim и JupyterLab;
- реальная browser-интерактивность;
- доступ к возможностям JupyterLab.

Ограничения:

- обязательна JupyterLab extension;
- отображение и выполнение зависят от браузера;
- архитектура не соответствует требованию интегрированного terminal-only интерфейса.

### 2.5. vim-jukit

Репозиторий: <https://github.com/luk400/vim-jukit>

Сильные стороны:

- REPL workflow;
- cell markers в обычных скриптах;
- операции над ячейками;
- конвертация в `.ipynb` и обратно;
- matplotlib-графики в Kitty/iTerm;
- сохранение некоторых outputs.

Ограничения:

- script-first, а не notebook-first архитектура;
- ограниченная поддержка полного nbformat;
- нет универсального rich MIME frontend;
- нет Plotly/Bokeh frontend.

### 2.6. Новые native `.ipynb` плагины

#### ajbucci/ipynb.nvim

Репозиторий: <https://github.com/ajbucci/ipynb.nvim>

Преимущества:

- native `.ipynb` editing;
- изолированные cell buffers;
- inline outputs и изображения;
- LSP и variable inspector;
- multi-language support.

Недостатки:

- проект явно помечен как alpha;
- code actions не поддерживаются из-за сложности edits через границы ячеек;
- изображения статические;
- нет интерактивного HTML/JS renderer.

#### ansh-info/ipynb.nvim

Репозиторий: <https://github.com/ansh-info/ipynb.nvim>

Преимущества:

- Colab-подобное представление;
- native notebook editing;
- kernel execution;
- inline outputs.

Недостатки:

- очень молодой проект;
- небольшая пользовательская база;
- изображения зависят от Kitty Unicode placeholders;
- интерактивные Plotly/Bokeh не решены.

#### notebook.nvim

Репозиторий: <https://github.com/likelikeslike/notebook.nvim>

Преимущества:

- `.ipynb` round-trip;
- текстовое представление с `# %%`;
- streaming output;
- image.nvim;
- LSP и variable inspector.

Недостатки:

- очень молодой проект;
- малая пользовательская база;
- percent-format остаётся скорее текстовой проекцией;
- нет универсального interactive renderer.

#### jupyter.nvim

Репозиторий: <https://github.com/sei40kr/jupyter.nvim>

Преимущества:

- kernel-backed completion и hover;
- `.ipynb` round-trip;
- async RPC;
- изображения через Snacks.

Недостатки:

- rich image support в основном ограничен PNG/JPEG;
- percent-format projection;
- нет интерактивных JavaScript outputs.

#### jupynvim

Репозиторий: <https://github.com/Matheus-OAMK/jupynvim>

Преимущества:

- понятная cell-centric навигация;
- Lua frontend и Rust backend;
- прямой Jupyter wire protocol;
- native `.ipynb` round-trip;
- сохранение неизвестных полей nbformat;
- direct Kitty rendering;
- LSP, который видит notebook code.

Недостатки:

- очень молодой проект;
- малая пользовательская база;
- ограниченный проверенный production experience;
- нет полного Plotly/Bokeh frontend.

jupynvim следует использовать как важный UX-референс, но не обязательно копировать его реализацию.

### 2.7. Euporie

Репозиторий: <https://github.com/joouha/euporie>

Документация:

- <https://euporie.readthedocs.io/en/stable/pages/overview.html>
- <https://euporie.readthedocs.io/en/stable/apps/notebook.html>

Euporie является главным функциональным ориентиром:

- редактирует и выполняет notebooks в терминале;
- показывает изображения через Kitty, Sixel и iTerm protocols;
- рендерит Markdown, таблицы, изображения, LaTeX, HTML, SVG и PDF;
- поддерживает terminal ipywidgets;
- имеет поддержку ipympl;
- предоставляет Vim-подобные keybindings.

Важный архитектурный вывод: Euporie переимплементирует многие ipywidgets в terminal-friendly виде. Терминал сам по себе не превращает browser-oriented MIME output в интерактивный UI.

В актуальном исходном коде Euporie не обнаружено отдельного Plotly или Bokeh renderer. Следовательно, для требуемой интерактивности нужен собственный frontend.

---

## 3. Текущая локальная среда

Обнаруженные версии:

- Neovim `0.12.5`;
- Kitty `0.48.2`;
- Python `3.14.7`;
- IPython `9.17.1`;
- ipykernel `7.3.0`;
- jupyter_client `8.10.0`;
- jupyter_server `2.21.1`;
- jupyterlab `4.6.3`;
- nbformat `5.11.1`;
- matplotlib установлен;
- Plotly, Kaleido, Bokeh и ipywidgets не установлены;
- доступен один kernelspec `python3`.

В Neovim-конфиге уже присутствуют:

- `molten-nvim`;
- `quarto-nvim`;
- `image.nvim`;
- `snacks.nvim` с включённым image module;
- `render-markdown.nvim`;
- Tree-sitter parsers для Python, Markdown и Markdown inline;
- Pyright и Ruff через Mason.

Выявленные потенциальные конфликты:

1. Molten и Quarto загружаются глобально с `lazy = false`.
2. Одновременно используются `image.nvim` и `Snacks.image`.
3. `render-markdown.nvim` объявлен дважды.
4. Quarto уже занимает `<leader>rc`, `<leader>ra` и `<leader>rl`.
5. `vim.g.python3_host_prog` указывает на `/usr/bin/python3`, но `pynvim` там отсутствует.
6. Shell Python проходит через pyenv, а `jupyter` запускается из `/usr/bin/jupyter`.

Плагин не должен зависеть от `python3_host_prog` или неявно выбирать одно из этих окружений.

Kitty настроен с remote control и Unix socket. Для обычного Kitty Graphics Protocol это не требуется. Использование remote control должно оставаться опциональным и не быть обязательным условием работы плагина.

---

## 4. Общая архитектура

```text
┌────────────────────────────────────────┐
│ Neovim plugin — Lua                   │
│                                        │
│ Notebook model                         │
│ Composite buffer                       │
│ Cell navigation                        │
│ LSP source maps                        │
│ Output compositor                      │
│ Kitty image placement                  │
│ Commands and keymaps                   │
└──────────────────┬─────────────────────┘
                   │ NDJSON или msgpack-RPC через stdio
          ┌────────▼─────────┐
          │ Python sidecar   │
          │ jupyter_client   │
          │ nbformat         │
          └────────┬─────────┘
                   │ ZMQ + Jupyter protocol
              Jupyter kernel

Интерактивные HTML/JS outputs:

┌─────────────────────┐       raster frame       ┌──────────────────┐
│ Headless renderer   │ ───────────────────────► │ Kitty placement  │
│ Chromium/Playwright │ ◄─────────────────────── │ inside Neovim    │
└─────────────────────┘       mouse/key events   └──────────────────┘
```

### 4.1. Ответственность Lua frontend

Lua отвечает за:

- notebook buffer;
- notebook model на стороне редактора;
- extmarks, virtual text и virtual lines;
- cell borders и statuses;
- navigation и structural editing;
- LSP shadow buffers и source maps;
- output placement;
- viewport tracking;
- mouse event routing;
- команды и пользовательскую конфигурацию.

Lua не должен самостоятельно реализовывать ZMQ, HMAC и Jupyter wire protocol.

### 4.2. Python sidecar

Использовать отдельный процесс, а не `pynvim` remote plugin.

Причины:

- `jupyter_client` уже реализует Jupyter transport;
- sidecar не зависит от Neovim Python host;
- kernel может использовать другое окружение;
- сбой sidecar не должен приводить к сбою Neovim;
- API между Lua и sidecar можно тестировать отдельно;
- легче реализовать attach к существующим kernels и Jupyter Server.

Функции sidecar:

- чтение, валидация и сериализация nbformat;
- kernelspec discovery;
- start/attach/shutdown/restart kernel;
- shell, control, stdin и IOPub channels;
- `execute_request`;
- `stream`, `error`, `execute_result`, `display_data`;
- `update_display_data`;
- `clear_output`;
- `input_request`;
- interrupt;
- comm messages для будущих widgets/ipympl.

Окружение sidecar следует создавать отдельно через `uv`.

---

## 5. Notebook model и composite buffer

### 5.1. Почему не отдельное окно на каждую ячейку

Neovim не умеет нативно составлять несколько buffers в одном окне. Попытка использовать отдельный видимый buffer для каждой ячейки существенно усложнит:

- cursor movement;
- undo/redo;
- registers и macros;
- visual selections;
- scrolling;
- search;
- folds;
- LSP mapping.

Рекомендуется один composite buffer и отдельная внутренняя notebook model.

### 5.2. Представление

- один `acwrite` buffer;
- стабильные `cell_id`;
- concealed structural markers;
- Markdown хранится как Markdown;
- code cells представлены fenced/injected regions;
- outputs не являются редактируемым текстом;
- output anchors и borders строятся через extmarks;
- normal mode показывает notebook presentation;
- structural/edit mode может раскрывать технические delimiters.

Обычный `# %%` формат не должен быть основным внутренним представлением, потому что Markdown приходится хранить в комментариях, а multi-language notebooks становятся неудобными.

### 5.3. Сохранение

Через `BufWriteCmd`:

1. composite buffer преобразуется в notebook cells;
2. обновляются `source`, `outputs`, `execution_count` и явно изменённые metadata;
3. неизвестные поля остаются без изменений;
4. notebook проверяется через `nbformat`;
5. выполняется атомарная запись через temporary file и rename.

Обязательно сохранять:

- notebook metadata;
- cell metadata;
- `cell.id`;
- attachments;
- неизвестные MIME types;
- extension-specific fields;
- outputs, которые frontend пока не умеет отображать;
- MIME bundles без потери альтернативных representations.

---

## 6. LSP-архитектура

### 6.1. Требование

LSP должен видеть код notebook как единый логический документ, чтобы определение из одной code cell корректно использовалось в других.

Отдельный LSP buffer на каждую ячейку неприемлем: сервер потеряет межъячеечный контекст.

### 6.2. Shadow documents

Для каждого языка создаётся скрытый объединённый документ:

```text
Visible notebook buffer
        │
        ├── Source map: notebook ranges ↔ shadow ranges
        │
        ├── Python shadow buffer ── Pyright / Ruff
        ├── R shadow buffer      ── R languageserver
        └── Julia shadow buffer  ── LanguageServer.jl
```

Пример Python shadow document:

```python
# cell: id-a
import numpy as np

# cell: id-b
def normalize(x):
    return x / np.linalg.norm(x)

# cell: id-c
normalize(...)
```

Стандартный LSP Notebook Document Protocol можно добавить как optional backend, но нельзя делать его единственным путём: многие language servers его не поддерживают. Shadow text documents обеспечивают более широкую совместимость.

### 6.3. Source map

Source map должен переводить:

- notebook row/column в shadow row/column;
- shadow diagnostics обратно в notebook;
- completion positions;
- hover и signature help ranges;
- definition/declaration locations;
- references;
- semantic tokens;
- text edits;
- WorkspaceEdits.

Source map должен иметь версию. Ответ от LSP, полученный для устаревшей версии, нельзя применять без повторной проверки.

### 6.4. Функции LSP для первой версии

Обязательны:

- diagnostics;
- completion;
- hover;
- signature help;
- go to definition;
- go to declaration;
- references;
- document symbols;
- rename;
- semantic tokens;
- code actions, если edits безопасно переводятся обратно.

### 6.5. WorkspaceEdits и code actions

Правила применения:

- edits внутри code cells применяются;
- edits в других project files применяются стандартно;
- edits синтетических separators игнорируются;
- edit, пересекающий code/Markdown boundary, отклоняется;
- edit, удаляющий cell marker, отклоняется;
- перед применением проверяется версия source map;
- пользователю показывается причина отклонения.

Это позволит не отключать code actions полностью, в отличие от некоторых существующих native notebook plugins.

### 6.6. IPython magics

Строки вида:

```python
%matplotlib inline
!pip install package
%%time
```

невалидны для обычного Python LSP.

Перед отправкой в shadow document они должны заменяться placeholders, сохраняющими:

- число строк;
- длину строки, где это необходимо для mapping;
- позиции последующего кода.

Позже можно добавить IPython-specific parser, но Pyright/Ruff не должны получать синтаксически сломанный документ.

### 6.7. Окружения LSP и kernel

Kernel и LSP могут использовать разные Python environments. Настройки должны разделяться:

```lua
kernel = {
  python = "...",
}

lsp = {
  python = "...",
  use_kernel_environment = true,
}
```

По умолчанию можно предлагать kernel environment для LSP, но пользователь должен иметь возможность явно выбрать другое.

---

## 7. Навигация и notebook UX

Навигация должна быть cell-centric и по удобству ориентироваться на jupynvim.

### 7.1. Базовые motions

Предлагаемые buffer-local mappings:

| Mapping | Действие |
|---|---|
| `]c` / `[c` | следующая/предыдущая ячейка |
| `]C` / `[C` | следующая/предыдущая code cell |
| `]o` / `[o` | следующий/предыдущий output |
| `]e` / `[e` | следующая/предыдущая ошибочная ячейка |
| `{count}]c` | переход на заданное число ячеек |
| `ic` / `ac` | inner/around cell text objects |
| `gg` / `G` | первая/последняя позиция с обычной Vim-семантикой |

Motions должны:

- добавлять переходы в jumplist;
- поддерживать counts;
- сохранять preferred column;
- работать в Normal, Visual и Operator-pending modes;
- не помещать курсор в concealed markers;
- учитывать folded/collapsed cells;
- не зависеть от высоты outputs или изображений.

Leader mappings не должны жёстко задаваться. В текущем конфиге `<leader>r*` уже занят Quarto. Предпочтительны configurable buffer-local mappings, например под `<localleader>j`.

### 7.2. Structural navigation

Нужны:

- notebook outline;
- переход по Markdown headings;
- список всех cells;
- фильтр code/Markdown/raw;
- переход по execution count;
- переход к running, stale и error cells;
- Telescope adapter;
- fallback на `vim.ui.select`.

Пример outline:

```text
Notebook
├─ 1  [md]   Data preparation
├─ 2  [12]   imports
├─ 3  [13]   load_dataset()
├─ 4  [md]   Model
├─ 5  [!]    train_model()
└─ 6  [ ]    Evaluation
```

### 7.3. Визуальное состояние

Активная ячейка должна иметь заметную, но не мешающую границу:

```text
╭─ Python · cell 5/12 · [running] · modified ─────────────
│ model.fit(x_train, y_train)
╰─────────────────────────────────────────────────────────
```

Header показывает:

- тип ячейки;
- язык;
- позицию;
- execution count;
- running/error/stale;
- collapsed source/output;
- modified state.

### 7.4. Структурные операции

- insert cell above/below;
- delete;
- duplicate;
- move up/down;
- split at cursor;
- merge above/below;
- code ↔ Markdown ↔ raw;
- collapse/expand source;
- collapse/expand output;
- clear current/all outputs.

Операции должны быть undoable через стандартный Neovim undo.

---

## 8. Выполнение ячеек

Команды:

- текущая ячейка;
- текущая с переходом к следующей;
- все предыдущие;
- все последующие;
- все ячейки;
- выбранный диапазон;
- interrupt;
- restart kernel;
- restart and run all;
- clear current/all outputs.

### 8.1. Семантика batch execution

Для `run above`, `run below` и `run all`:

1. создаётся immutable snapshot списка cell IDs;
2. Markdown и raw cells пропускаются;
3. code cells ставятся в последовательную очередь;
4. configurable `stop_on_error` определяет поведение после ошибки;
5. output связывается с cell ID через `parent_header.msg_id`;
6. execution result привязывается к revision source;
7. изменение cell во время выполнения помечает результат как stale;
8. повторный запуск обрабатывается по явной политике queue/cancel/replace.

Статусы:

```text
[ ] not executed
[…] queued
[▶] running
[12] completed
[!] failed
[*] stale output
```

---

## 9. Рендеринг outputs

### 9.1. Текст

Поддержать:

- `stream`;
- `text/plain`;
- ANSI colors;
- traceback;
- wrapping;
- configurable truncation;
- полный output во floating window;
- копирование без terminal escape sequences.

Большие outputs хранятся полностью в модели, но показываются ограниченным количеством virtual lines.

### 9.2. Markdown и HTML

- `text/markdown` рендерится terminal Markdown renderer;
- безопасный HTML subset преобразуется в styled terminal text;
- таблицы имеют отдельный renderer;
- raw HTML/JavaScript не исполняется автоматически;
- HTML/JS допускается только для trusted notebooks в sandboxed renderer.

`render-markdown.nvim` можно поддержать как optional adapter, но ядро не должно зависеть от него.

### 9.3. Статические изображения

Рекомендуемый MIME priority:

1. `image/png`;
2. `image/jpeg`;
3. `image/svg+xml` с rasterization;
4. `application/pdf` с rasterization;
5. `text/plain` fallback.

Абстрактный интерфейс image renderer:

```text
show
update
hide
delete
set_viewport
```

Первоначально допустим adapter к `Snacks.image` или `image.nvim`. Для интерактивных кадров и точного управления placements потребуется собственный Kitty backend.

Собственный backend должен поддерживать:

- стабильные image IDs;
- placement IDs;
- viewport synchronization;
- update существующего изображения;
- удаление placements;
- animation frames;
- coordinate mapping для мыши.

---

## 10. Plotly и Bokeh

### 10.1. Ограничения Kitty Graphics Protocol

Документация: <https://sw.kovidgoyal.net/kitty/graphics-protocol/>

Kitty умеет:

- передавать PNG, RGB и RGBA data;
- размещать изображения по terminal cells;
- обновлять изображения;
- поддерживать animation frames;
- управлять image и placement IDs.

Kitty не предоставляет:

- DOM;
- JavaScript runtime;
- HTML layout engine;
- Plotly.js или BokehJS;
- автоматическую передачу mouse events элементам внутри изображения.

Следовательно, полноценная интерактивность требует application-level frontend.

### 10.2. Headless renderer

Предлагаемый подход:

1. kernel возвращает Plotly/Bokeh MIME bundle;
2. headless Chromium загружает локальный Plotly.js или BokehJS;
3. график строится в невидимой странице;
4. renderer делает screenshot области графика;
5. Neovim показывает кадр через Kitty;
6. Neovim перехватывает click, move, drag, wheel и keyboard events;
7. terminal coordinates переводятся в DOM pixel coordinates;
8. события отправляются в headless browser;
9. после изменения renderer отправляет обновлённый кадр.

Для пользователя всё остаётся внутри Neovim и Kitty; отдельное browser window не открывается.

### 10.3. Первая поддерживаемая интерактивность

Plotly standalone:

- hover;
- pan;
- wheel zoom;
- box zoom;
- reset;
- legend toggles;
- выбор точек, если не нужен внешний callback.

Bokeh standalone:

- pan;
- zoom;
- hover;
- tap/select;
- toolbar actions, не требующие Bokeh server.

Не обещать в первой версии:

- Bokeh server apps;
- Dash;
- произвольный JavaScript;
- Python callbacks;
- полный ipywidgets ecosystem;
- высокий animation FPS.

`ipympl` следует реализовать отдельным этапом через Jupyter comm protocol, используя Euporie как архитектурный ориентир.

### 10.4. Безопасность

Interactive HTML renderer должен быть отключён для untrusted notebooks.

Sandbox requirements:

- отдельный temporary Chromium profile;
- сеть запрещена по умолчанию;
- `file://` запрещён;
- Plotly.js и BokehJS поставляются локально;
- строгий CSP;
- limits на CPU, memory и output dimensions;
- explicit notebook trust;
- страница не получает shell или filesystem APIs.

---

## 11. Этапы разработки

### Этап 0 — спецификация и fixtures

- определить поддерживаемый subset nbformat 4;
- описать protocol между Lua, sidecar и renderer;
- определить kernel и execution state machines;
- определить модель trust;
- собрать notebook fixtures;
- зафиксировать критерий lossless round-trip.

Fixtures:

- Markdown;
- code cells;
- streams;
- errors;
- stdin;
- matplotlib;
- `display_id` updates;
- `clear_output`;
- attachments;
- unknown metadata;
- Plotly;
- Bokeh;
- large outputs;
- Unicode.

### Этап 1 — notebook model и navigation

- load/save `.ipynb`;
- composite buffer;
- stable cell IDs;
- borders и statuses;
- cell motions;
- text objects;
- structural operations;
- outline;
- Markdown heading navigation;
- undo/redo;
- validation и atomic save.

Критерий завершения: notebook можно открыть, полноценно отредактировать, изменить структуру и сохранить без потери metadata и outputs.

### Этап 2 — LSP foundation

Статус: реализован вместе с projected Tree-sitter highlighting; детали и ограничения описаны в [`docs/stage2.md`](stage2.md).

- shadow documents;
- multi-language source maps;
- diagnostics;
- completion;
- hover;
- signature help;
- definitions/declarations;
- references;
- symbols;
- semantic tokens;
- rename;
- безопасные WorkspaceEdits;
- IPython magics preprocessing;
- Pyright/Ruff integration tests.

LSP должен быть реализован до kernel execution, чтобы buffer model и source mapping не пришлось переделывать позднее.

### Этап 3 — kernel execution

Статус: реализован. Детали и команды описаны в [`stage3.md`](stage3.md).

- Python sidecar;
- kernel lifecycle;
- current/above/below/all;
- sequential execution queue;
- streaming output;
- errors;
- stdin;
- interrupt;
- restart;
- execution counts;
- stale output tracking;
- output persistence.

### Этап 4 — rich static outputs

Статус: реализован. Детали протокола, fallback и security limits описаны в
[`docs/stage4.md`](stage4.md).

- Markdown;
- HTML subset;
- tables;
- PNG/JPEG/SVG/PDF;
- matplotlib;
- output float/pager;
- viewport-aware image placement;
- terminal capability detection;
- fallback без Kitty.

### Этап 5 — Plotly proof of concept

Статус: реализован. Архитектура, security boundary, команды и ограничения описаны в
[`docs/stage5.md`](stage5.md).

- headless renderer process;
- Plotly MIME loading;
- screenshot to Kitty;
- click/drag/wheel forwarding;
- hover;
- pan/zoom;
- frame throttling;
- focus mode;
- latency measurement.

Это архитектурный gate. Bokeh добавляется только после подтверждения приемлемой задержки и стабильности.

### Этап 6 — production interactive renderer

Статус: реализован. Trust model, sandbox, Awrit external focus без screenshot
pipeline, резервный push/pull TUI renderer, recovery, performance measurements
и ограничения описаны в [`docs/stage6.md`](stage6.md).

- Bokeh standalone;
- resize;
- keyboard events;
- multiple visible figures;
- renderer crash recovery;
- cleanup;
- sandbox;
- notebook trust;
- performance profiling.

### Этап 7 — расширение и polish

Статус: реализован. Границы безопасной terminal projection, read-only widget UI,
remote transport и optional integrations описаны в [`docs/stage7.md`](stage7.md).

- ipympl: live PNG/data-url canvas frames без выполнения frontend JavaScript; browser-grade input остаётся отдельным расширением;
- базовые ipywidgets: безопасная terminal projection для label/HTML/button/checkbox/text/slider/select/progress;
- remote Jupyter Server через authenticated REST lifecycle и bounded WebSocket v1 channels;
- variable inspector;
- kernel-backed completion как optional nvim-cmp source;
- statusline adapters;
- Telescope integration;
- расширенные health checks.

### Этап 8 — remote file exchange

Статус: реализован. Детали UI, Contents API, limits и bindings описаны в
[`docs/stage8.md`](stage8.md).

- authenticated Jupyter Contents API для list/stat/create/rename/delete/upload/download;
- byte-preserving binary и notebook transfer;
- двухпанельный Telescope UI для local/remote файловых систем;
- nvim-tree-style create/open/rename/delete/copy/cut/paste/refresh/navigation bindings;
- рекурсивное копирование и перемещение внутри и между файловыми системами;
- path traversal, redirect, size/count/timeout и aggregate-transfer bounds;
- real Jupyter Server и real Telescope E2E.

---

## 12. Тестовая стратегия

### 12.1. Два Neovim-профиля

#### Минимальный hermetic profile

Используются отдельные:

```text
XDG_CONFIG_HOME
XDG_DATA_HOME
XDG_STATE_HOME
XDG_CACHE_HOME
```

Подключаются только:

- Neovim;
- разрабатываемый plugin;
- минимальные pinned dependencies;
- test mappings;
- необходимые Tree-sitter parsers.

Этот профиль используется в unit/integration CI.

#### Compatibility profile

На каждый запуск:

1. копировать `/home/i3alumba/.config/nvim` в временный каталог;
2. назначать отдельные XDG data/state/cache directories;
3. сохранять текущий `lazy-lock.json`;
4. добавлять локальный plugin через runtimepath/lazy dev path;
5. не изменять исходный пользовательский config;
6. тестировать совместимость с Molten, Quarto, Snacks и image.nvim.

Персональный config snapshot не должен содержать secrets и не обязан коммититься в публичный репозиторий.

### 12.2. Docker

Docker используется для:

- Lua tests;
- Python tests;
- nbformat round-trip;
- headless Neovim;
- real ipykernel;
- Plotly/Bokeh renderer;
- Playwright tests;
- reproducible CI.

Docker недостаточен для финальной визуальной проверки Kitty graphics, потому что container не является настоящим terminal frontend.

### 12.3. Host Kitty E2E

Отдельный host-only test suite:

- запуск Kitty с отдельным test config;
- запуск тестового Neovim внутри Kitty;
- PNG placement/update/delete;
- scrolling;
- resize;
- несколько изображений;
- Plotly mouse events;
- screenshot diffs;
- cleanup после закрытия buffer/window.

### 12.4. Lua unit tests

- cell range calculation;
- extmark placement;
- structural edits;
- motions и counts;
- text objects;
- execution selection;
- output anchors;
- viewport mapping;
- mouse coordinate mapping;
- source map translation.

### 12.5. Python unit tests

- RPC serialization;
- nbformat validation;
- MIME priority;
- unknown metadata preservation;
- kernelspec discovery;
- execution message routing;
- restart и interrupt state transitions.

### 12.6. Kernel integration tests

- stream;
- execute result;
- display data;
- error;
- stdin;
- interrupt;
- `clear_output`;
- `update_display_data`;
- restart;
- kernel death;
- multiple queued cells.

### 12.7. LSP tests

Обязательные сценарии:

1. Определение в первой code cell используется в последующей.
2. Вставка строк в Markdown не ломает diagnostics mapping.
3. Добавление, удаление и перемещение code cell перестраивает source map.
4. Unicode корректно переводится между byte columns Neovim и UTF-16 LSP positions.
5. Rename изменяет символ во всех code cells.
6. Go-to-definition переходит в другую cell.
7. Definition во внешнем `.py` открывает файл, а jumplist возвращает в notebook.
8. Code action не может удалить cell boundary.
9. Diagnostics от IPython magics корректно подавляются или переводятся.
10. Разные языки не отправляются одному LSP client.
11. Restart LSP восстанавливает shadow documents.
12. Completion остаётся асинхронным во время выполнения kernel.
13. Устаревший LSP response не применяется к новой версии source map.
14. WorkspaceEdit во внешнем project file применяется стандартно.

Для position mapping нужны как mock LSP tests, так и integration tests с реальными Pyright и Ruff.

### 12.8. Round-trip и property tests

- `load → save` без редактирования семантически сохраняет notebook;
- неизвестные поля сохраняются;
- cell IDs не меняются;
- attachments сохраняются;
- MIME bundles сохраняются;
- outputs не теряются при отсутствии renderer;
- structural edits создают валидный nbformat.

### 12.9. Interactive renderer tests

- Plotly/Bokeh golden screenshots;
- hover;
- pan;
- zoom;
- legend toggles;
- resize;
- network sandbox;
- blocked file access;
- renderer crash recovery;
- event coordinate mapping;
- frame throttling.

### 12.10. Compatibility tests

- запуск с полным пользовательским config;
- отсутствие command/autocmd/keymap conflicts;
- корректное отключение Molten/Quarto только для `.ipynb` при необходимости;
- совместимость с Snacks.image и image.nvim;
- отсутствие изменений в реальном XDG state пользователя.

---

## 13. Scope версий

### v0.1

- native `.ipynb` load/save;
- code, Markdown и raw cells;
- cell-centric navigation уровня jupynvim;
- structural editing;
- outline;
- полноценный LSP через shadow documents;
- current/above/below/all execution;
- kernel lifecycle;
- text, stream и error outputs;
- matplotlib PNG;
- Kitty rendering;
- lossless nbformat round-trip;
- isolated test config и Docker CI.

### v0.2

- HTML/table renderer;
- SVG/PDF;
- Plotly remote framebuffer;
- notebook trust;
- sandboxed Chromium;
- улучшенная image placement и viewport handling.

### v0.3

- Bokeh standalone;
- ipympl;
- базовые ipywidgets;
- remote Jupyter Server;
- richer multi-language support;
- variable inspector.

---

## 14. Основные риски

### LSP mapping

Самая важная сложность редакторной части. Source maps должны проектироваться одновременно с notebook buffer, а не добавляться после реализации UI.

### Lossless nbformat round-trip

Нельзя сериализовать только известный subset полей. Неизвестные metadata и MIME representations должны сохраняться.

### Kitty image lifecycle

Нужно корректно обрабатывать scrolling, resize, folds, hidden windows, buffer close и stale placements.

### Interactive latency

Headless browser → screenshot → Kitty может иметь заметную задержку. Plotly proof of concept должен подтвердить UX до реализации Bokeh и widgets.

### Security

Notebook HTML и JavaScript нельзя считать доверенными. Trust и sandbox являются обязательными условиями включения интерактивного renderer.

### Персональный Neovim config

Существующие Molten, Quarto, image.nvim и Snacks могут конфликтовать с BufReadCmd, mappings и image placements. Compatibility profile должен использоваться с первых этапов.

---

## 15. Критерии успешности

Плагин можно считать достигшим основной цели, если:

1. `.ipynb` открывается как понятный notebook, а не JSON.
2. Навигация по cells не менее удобна, чем в jupynvim.
3. LSP видит код между ячейками и корректно выполняет diagnostics, completion, definitions, references и rename.
4. Все требуемые режимы запуска работают последовательно и предсказуемо.
5. Notebook сохраняется без потери неизвестных metadata и outputs.
6. Matplotlib отображается внутри Kitty.
7. Plotly и Bokeh доступны интерактивно без отдельного browser window.
8. Untrusted HTML/JavaScript не исполняется автоматически.
9. Тесты работают в минимальном config и в изолированной копии пользовательского config.
10. Реальные конфиги и XDG directories пользователя никогда не изменяются тестами.

---

## 16. Основные источники

- Euporie: <https://github.com/joouha/euporie>
- Euporie overview: <https://euporie.readthedocs.io/en/stable/pages/overview.html>
- Euporie Notebook: <https://euporie.readthedocs.io/en/stable/apps/notebook.html>
- Euporie ipywidgets: <https://github.com/joouha/euporie/blob/dev/docs/pages/ipywidgets.rst>
- Kitty Graphics Protocol: <https://sw.kovidgoyal.net/kitty/graphics-protocol/>
- Kitty Keyboard Protocol: <https://sw.kovidgoyal.net/kitty/keyboard-protocol/>
- Kitty Remote Control: <https://sw.kovidgoyal.net/kitty/remote-control/>
- Jupyter messaging protocol: <https://jupyter-client.readthedocs.io/en/stable/messaging.html>
- Notebook format specification: <https://nbformat.readthedocs.io/en/latest/format_description.html>
- Neovim API: <https://neovim.io/doc/user/api.html>
- Molten: <https://github.com/benlubas/molten-nvim>
- Quarto.nvim: <https://github.com/quarto-dev/quarto-nvim>
- Jupytext.nvim: <https://github.com/GCBallesteros/jupytext.nvim>
- Neopyter: <https://github.com/SUSTech-data/neopyter>
- vim-jukit: <https://github.com/luk400/vim-jukit>
- image.nvim: <https://github.com/3rd/image.nvim>
- Snacks image: <https://github.com/folke/snacks.nvim/blob/main/docs/image.md>
- ajbucci/ipynb.nvim: <https://github.com/ajbucci/ipynb.nvim>
- ansh-info/ipynb.nvim: <https://github.com/ansh-info/ipynb.nvim>
- notebook.nvim: <https://github.com/likelikeslike/notebook.nvim>
- jupyter.nvim: <https://github.com/sei40kr/jupyter.nvim>
- jupynvim: <https://github.com/Matheus-OAMK/jupynvim>
