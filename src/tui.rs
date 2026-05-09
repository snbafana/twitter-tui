use std::sync::mpsc;
use std::time::Duration;

use anyhow::{Context, Result};
use ratatui::crossterm::event::{self, Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::crossterm::execute;
use ratatui::crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::layout::Position;
use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Style};
use ratatui::text::Line;
use ratatui::widgets::{Block, Borders, Paragraph, Wrap};
use tui_textarea::{CursorMove, TextArea};
use unicode_width::UnicodeWidthChar;

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
    let mut composer_width = 1usize;

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
            let layout = composer_layout(frame.area());
            composer_width = text_width(layout.composer);

            frame.render_widget(&textarea, layout.composer);
            if let Some(cursor_position) = cursor_position_in_area(&textarea, layout.composer) {
                frame.set_cursor_position(cursor_position);
            }

            let status =
                composer_status(&me.username, textarea.lines(), pending, layout.status.width);
            let meta = Paragraph::new(Line::from(status.text))
                .style(Style::default().fg(status.color))
                .wrap(Wrap { trim: true });
            let footer_widget =
                Paragraph::new(footer_text(&footer, &last_post_id)).wrap(Wrap { trim: true });

            frame.render_widget(meta, layout.status);
            frame.render_widget(footer_widget, layout.footer);
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
            composer_width,
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
    if modified && should_soft_wrap(key) {
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

struct ComposerLayout {
    composer: Rect,
    status: Rect,
    footer: Rect,
}

struct ComposerStatus {
    text: String,
    color: Color,
}

fn composer_layout(area: Rect) -> ComposerLayout {
    let areas = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(3),
            Constraint::Length(1),
            Constraint::Length(2),
        ])
        .split(area);

    ComposerLayout {
        composer: areas[0],
        status: areas[1],
        footer: areas[2],
    }
}

fn text_width(area: Rect) -> usize {
    area.width.saturating_sub(2).max(1) as usize
}

fn composer_status(
    username: &str,
    lines: &[String],
    pending: bool,
    available_width: u16,
) -> ComposerStatus {
    let raw_count = lines.join("\n").chars().count();
    let remaining = RAW_CHAR_LIMIT as isize - raw_count as isize;
    let color = if pending {
        Color::Yellow
    } else if remaining < 0 {
        Color::Red
    } else if remaining < 20 {
        Color::Yellow
    } else {
        Color::Green
    };
    let remaining_text = if remaining >= 0 {
        format!("{remaining} left")
    } else {
        format!("{} over", remaining.abs())
    };
    let action_text = if pending {
        "sending..."
    } else {
        "F5 send | Ctrl-L clear | Esc/Ctrl-C quit"
    };
    let text = if available_width < 34 {
        format!("{raw_count}/{RAW_CHAR_LIMIT}  {remaining_text}")
    } else if available_width < 58 {
        format!("@{username}  {raw_count}/{RAW_CHAR_LIMIT}  {remaining_text}  {action_text}")
    } else {
        format!("@{username}  {raw_count} raw chars  {remaining_text}  {action_text}")
    };

    ComposerStatus { text, color }
}

fn footer_text(footer: &str, last_post_id: &str) -> String {
    if last_post_id.is_empty() {
        footer.to_string()
    } else {
        format!("{footer} | last post id: {last_post_id}")
    }
}

fn soft_wrap_tail(textarea: &mut TextArea<'_>, wrap_width: usize) {
    if wrap_width == 0 {
        return;
    }

    loop {
        let (row, col) = textarea.cursor();
        let Some(line) = textarea.lines().get(row) else {
            return;
        };

        let line_len = line.chars().count();
        if col != line_len || display_width(line) <= wrap_width {
            return;
        }

        let Some(split_col) = wrap_split_col(line, wrap_width) else {
            return;
        };
        if split_col == 0 || split_col >= line_len {
            return;
        }

        textarea.move_cursor(CursorMove::Jump(row as u16, split_col as u16));
        textarea.insert_newline();
        textarea.move_cursor(CursorMove::End);
    }
}

fn should_soft_wrap(key: KeyEvent) -> bool {
    match key.code {
        KeyCode::Char(_) => !key
            .modifiers
            .intersects(KeyModifiers::CONTROL | KeyModifiers::ALT),
        KeyCode::Tab => true,
        _ => false,
    }
}

fn cursor_position_in_area(textarea: &TextArea<'_>, area: Rect) -> Option<Position> {
    let inner = textarea.block().map_or(area, |block| block.inner(area));
    if inner.width == 0 || inner.height == 0 {
        return None;
    }

    let (row, col) = textarea.cursor();
    let line = textarea.lines().get(row)?;
    let x = inner.x.saturating_add(
        display_width_up_to(line, col).min(inner.width.saturating_sub(1) as usize) as u16,
    );
    let y = inner
        .y
        .saturating_add((row as u16).min(inner.height.saturating_sub(1)));
    Some(Position::new(x, y))
}

fn wrap_split_col(line: &str, wrap_width: usize) -> Option<usize> {
    let mut width = 0usize;
    let mut col = 0usize;

    for ch in line.chars() {
        let ch_width = ch.width().unwrap_or(0);
        if width + ch_width > wrap_width {
            return Some(col);
        }
        width += ch_width;
        col += 1;
    }

    Some(col)
}

fn display_width(line: &str) -> usize {
    display_width_up_to(line, line.chars().count())
}

fn display_width_up_to(line: &str, col: usize) -> usize {
    line.chars()
        .take(col)
        .map(|ch| ch.width().unwrap_or(0))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wraps_ascii_tail_and_keeps_cursor_after_wrapped_text() {
        let mut textarea = TextArea::default();
        textarea.insert_str("hello!");

        soft_wrap_tail(&mut textarea, 5);

        assert_eq!(textarea.lines(), ["hello", "!"]);
        assert_eq!(textarea.cursor(), (1, 1));
    }

    #[test]
    fn wraps_multi_cell_tail_using_display_width() {
        let mut textarea = TextArea::default();
        textarea.insert_str("abcd😄");

        soft_wrap_tail(&mut textarea, 5);

        assert_eq!(textarea.lines(), ["abcd", "😄"]);
        assert_eq!(textarea.cursor(), (1, 1));
    }

    #[test]
    fn wraps_repeatedly_when_inserted_tail_is_still_too_wide() {
        let mut textarea = TextArea::default();
        textarea.insert_str("abcdefghi");

        soft_wrap_tail(&mut textarea, 3);

        assert_eq!(textarea.lines(), ["abc", "def", "ghi"]);
        assert_eq!(textarea.cursor(), (2, 3));
    }

    #[test]
    fn skips_wrap_when_cursor_is_not_at_line_end() {
        let mut textarea = TextArea::from(["abcdef"]);
        textarea.move_cursor(CursorMove::Jump(0, 3));

        soft_wrap_tail(&mut textarea, 4);

        assert_eq!(textarea.lines(), ["abcdef"]);
        assert_eq!(textarea.cursor(), (0, 3));
    }

    #[test]
    fn clamps_cursor_inside_bordered_text_area() {
        let mut textarea = new_textarea();
        textarea.insert_str("hello");

        let position = cursor_position_in_area(
            &textarea,
            Rect {
                x: 10,
                y: 4,
                width: 7,
                height: 4,
            },
        )
        .expect("cursor should be visible");

        assert_eq!(position, Position::new(15, 5));
    }

    #[test]
    fn status_uses_short_copy_on_narrow_terminals() {
        let lines = vec!["hello".to_string()];

        let status = composer_status("snbafana", &lines, false, 20);

        assert_eq!(status.text, "5/280  275 left");
        assert_eq!(status.color, Color::Green);
    }

    #[test]
    fn status_warns_when_over_limit() {
        let lines = vec!["x".repeat(RAW_CHAR_LIMIT + 2)];

        let status = composer_status("snbafana", &lines, false, 80);

        assert!(status.text.contains("2 over"));
        assert_eq!(status.color, Color::Red);
    }

    #[test]
    fn footer_includes_last_post_id_when_present() {
        assert_eq!(
            footer_text("posted successfully", "123"),
            "posted successfully | last post id: 123"
        );
    }

    #[test]
    fn soft_wrap_only_runs_for_text_insertion_keys() {
        assert!(should_soft_wrap(KeyEvent::new(
            KeyCode::Char('a'),
            KeyModifiers::NONE,
        )));
        assert!(should_soft_wrap(KeyEvent::new(
            KeyCode::Tab,
            KeyModifiers::NONE,
        )));
        assert!(!should_soft_wrap(KeyEvent::new(
            KeyCode::Backspace,
            KeyModifiers::NONE,
        )));
        assert!(!should_soft_wrap(KeyEvent::new(
            KeyCode::Char('w'),
            KeyModifiers::CONTROL,
        )));
    }
}
