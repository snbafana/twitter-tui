use std::sync::mpsc;
use std::time::Duration;

use anyhow::{Context, Result};
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::layout::Position;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Style};
use ratatui::text::Line;
use ratatui::widgets::{Block, Borders, Paragraph};
use tui_textarea::{CursorMove, TextArea};

use crate::api::{CreatePostResult, XClient};
use crate::auth::TokenSession;
use crate::config::ConfigStore;

const RAW_CHAR_LIMIT: usize = 280;

pub fn run(api: XClient, store: ConfigStore, session: TokenSession) -> Result<()> {
    let mut terminal = setup_terminal()?;
    let result = run_inner(&mut terminal, api, store, session);
    restore_terminal(&mut terminal)?;
    result
}

fn run_inner(
    terminal: &mut ratatui::DefaultTerminal,
    api: XClient,
    mut store: ConfigStore,
    mut session: TokenSession,
) -> Result<()> {
    let (me, auth_changed) = api.get_authenticated_user(&mut session)?;
    persist_session_if_needed(&mut store, &session, auth_changed)?;

    let (cmd_tx, cmd_rx) = mpsc::channel::<WorkerCommand>();
    let (evt_tx, evt_rx) = mpsc::channel::<WorkerEvent>();
    std::thread::spawn(move || worker_loop(api, store, session, cmd_rx, evt_tx));

    let mut textarea = new_textarea();

    let mut footer = format!("authenticated as @{}", me.username);
    let mut last_post_id = String::new();
    let mut pending = false;
    let mut wrap_width = 1usize;

    loop {
        while let Ok(event) = evt_rx.try_recv() {
            match event {
                WorkerEvent::Posted(Ok(posted)) => {
                    footer = format!("posted {} successfully", posted.id);
                    last_post_id = posted.id;
                    pending = false;
                    textarea = new_textarea();
                }
                WorkerEvent::Posted(Err(err)) => {
                    footer = format!("post failed: {err}");
                    pending = false;
                }
            }
        }

        terminal.draw(|frame| {
            let areas = Layout::default()
                .direction(Direction::Vertical)
                .constraints([
                    Constraint::Min(6),
                    Constraint::Length(2),
                    Constraint::Length(2),
                ])
                .split(frame.area());

            wrap_width = areas[0].width.saturating_sub(2).max(1) as usize;
            frame.render_widget(&textarea, areas[0]);
            let (cursor_row, cursor_col) = textarea.cursor();
            frame.set_cursor_position(Position::new(cursor_col as u16, cursor_row as u16));

            let body = textarea.lines().join("\n");
            let raw_count = body.chars().count();
            let remaining = RAW_CHAR_LIMIT as isize - raw_count as isize;
            let status_color = if pending {
                Color::Yellow
            } else if remaining < 0 {
                Color::Red
            } else if remaining < 20 {
                Color::Yellow
            } else {
                Color::Green
            };
            let meta = Paragraph::new(Line::from(format!(
                "@{}  {} raw chars  {}  {}",
                me.username,
                raw_count,
                if remaining >= 0 {
                    format!("{remaining} left")
                } else {
                    format!("{} over", remaining.abs())
                },
                if pending {
                    "sending..."
                } else {
                    "F5 send | Ctrl-L clear | Esc/Ctrl-C quit"
                }
            )))
            .style(Style::default().fg(status_color));

            let footer_text = if last_post_id.is_empty() {
                footer.clone()
            } else {
                format!("{footer} | last post id: {last_post_id}")
            };
            let footer_widget = Paragraph::new(footer_text);

            frame.render_widget(meta, areas[1]);
            frame.render_widget(footer_widget, areas[2]);
        })?;

        if !event::poll(Duration::from_millis(100))? {
            continue;
        }

        let Event::Key(key) = event::read()? else {
            continue;
        };

        if handle_global_keys(
            &mut textarea,
            key,
            &mut pending,
            &cmd_tx,
            &mut footer,
            wrap_width,
        )? {
            break;
        }
    }

    Ok(())
}

fn handle_global_keys(
    textarea: &mut TextArea<'_>,
    key: KeyEvent,
    pending: &mut bool,
    cmd_tx: &mpsc::Sender<WorkerCommand>,
    footer: &mut String,
    wrap_width: usize,
) -> Result<bool> {
    match (key.code, key.modifiers) {
        (KeyCode::Esc, _) | (KeyCode::Char('c'), KeyModifiers::CONTROL) => return Ok(true),
        (KeyCode::F(5), _) => {
            if *pending {
                *footer = "request already in flight".to_string();
                return Ok(false);
            }

            let body = textarea.lines().join("\n");
            let trimmed = body.trim().to_string();
            if trimmed.is_empty() {
                *footer = "cannot send an empty post".to_string();
                return Ok(false);
            }

            *footer = "sending post...".to_string();
            cmd_tx
                .send(WorkerCommand::Post(trimmed))
                .context("failed to queue post request")?;
            *pending = true;
            return Ok(false);
        }
        (KeyCode::Char('l'), KeyModifiers::CONTROL) => {
            *textarea = new_textarea();
            *footer = "composer cleared".to_string();
            return Ok(false);
        }
        _ => {}
    }

    let modified = textarea.input(key);
    if modified {
        soft_wrap_tail(textarea, wrap_width);
    }
    Ok(false)
}

fn worker_loop(
    api: XClient,
    mut store: ConfigStore,
    mut session: TokenSession,
    cmd_rx: mpsc::Receiver<WorkerCommand>,
    evt_tx: mpsc::Sender<WorkerEvent>,
) {
    while let Ok(command) = cmd_rx.recv() {
        match command {
            WorkerCommand::Post(text) => {
                let result =
                    api.create_post(&mut session, &text)
                        .and_then(|(posted, auth_changed)| {
                            persist_session_if_needed(&mut store, &session, auth_changed)?;
                            Ok(posted)
                        });
                let _ = evt_tx.send(WorkerEvent::Posted(result));
            }
        }
    }
}

fn setup_terminal() -> Result<ratatui::DefaultTerminal> {
    enable_raw_mode().context("failed to enable raw mode")?;
    execute!(std::io::stdout(), EnterAlternateScreen).context("failed to enter alt screen")?;
    Ok(ratatui::init())
}

fn restore_terminal(terminal: &mut ratatui::DefaultTerminal) -> Result<()> {
    disable_raw_mode().context("failed to disable raw mode")?;
    execute!(std::io::stdout(), LeaveAlternateScreen).context("failed to leave alt screen")?;
    ratatui::restore();
    terminal.clear().ok();
    Ok(())
}

enum WorkerCommand {
    Post(String),
}

enum WorkerEvent {
    Posted(Result<CreatePostResult>),
}

fn persist_session_if_needed(
    store: &mut ConfigStore,
    session: &TokenSession,
    auth_changed: bool,
) -> Result<()> {
    if auth_changed {
        store.persist_auth(session.export())?;
    }

    Ok(())
}

fn new_textarea() -> TextArea<'static> {
    let mut textarea = TextArea::default();
    textarea.set_block(Block::default().borders(Borders::ALL).title("Compose"));
    textarea.set_cursor_line_style(Style::default());
    textarea.set_placeholder_text("Write a post. F5 sends. Esc quits.");
    textarea
}

fn soft_wrap_tail(textarea: &mut TextArea<'_>, wrap_width: usize) {
    let (row, col) = textarea.cursor();
    let Some(line) = textarea.lines().get(row) else {
        return;
    };

    let line_len = line.chars().count();
    if wrap_width == 0 || line_len <= wrap_width || col != line_len {
        return;
    }

    textarea.move_cursor(CursorMove::Back);
    textarea.insert_newline();
}
