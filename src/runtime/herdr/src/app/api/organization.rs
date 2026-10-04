use std::collections::HashSet;

use teaser_core::{Apply, Binding, Command, Snapshot};

use crate::api::schema::{EventData, EventEnvelope, EventKind, ResponseResult};
use crate::app::App;

use super::responses::{encode_error, encode_success};

const MAX_ORGANIZATION_BYTES: usize = 1_048_576;

impl App {
    pub(super) fn handle_organization_snapshot(&mut self, id: String) -> String {
        self.reconcile_organization_bindings();
        encode_success(
            id,
            ResponseResult::TeaserOrganizationSnapshot {
                snapshot: self.state.teaser_organization.clone(),
            },
        )
    }

    pub(super) fn handle_organization_apply(&mut self, id: String, params: Apply) -> String {
        self.reconcile_organization_bindings();
        let next: Snapshot = match self.state.teaser_organization.applying(&params) {
            Ok(next) => next,
            Err(error) => return encode_error(id, error.code(), error.code()),
        };
        let available: HashSet<String> = self.organization_terminal_panes();
        // Validate every explicit binding, even if a later command deletes/rebinds it.
        for command in &params.commands {
            let binding: Option<&Binding> = match command {
                Command::CreatePanel { panel } => Some(&panel.binding),
                Command::RebindPanel { binding, .. } => Some(binding),
                _ => None,
            };
            if let Some(Binding::Terminal { pane_id }) = binding {
                if !available.contains(pane_id) {
                    return encode_error(id, "invalid_binding", "terminal pane does not exist");
                }
            }
        }
        match serde_json::to_vec(&next) {
            Ok(encoded) if encoded.len() <= MAX_ORGANIZATION_BYTES => {}
            Ok(_) => return encode_error(id, "limit_exceeded", "organization exceeds 1 MiB"),
            Err(error) => return encode_error(id, "invalid_value", error.to_string()),
        }
        self.state.teaser_organization = next;
        self.organization_changed();
        encode_success(
            id,
            ResponseResult::TeaserOrganizationSnapshot {
                snapshot: self.state.teaser_organization.clone(),
            },
        )
    }

    fn organization_terminal_panes(&self) -> HashSet<String> {
        self.state
            .workspaces
            .iter()
            .enumerate()
            .flat_map(|(workspace_index, workspace)| {
                workspace.tabs.iter().flat_map(move |tab| {
                    tab.panes.iter().filter_map(move |(pane_id, pane)| {
                        self.state
                            .terminals
                            .contains_key(&pane.attached_terminal_id)
                            .then(|| self.public_pane_id(workspace_index, *pane_id))
                            .flatten()
                    })
                })
            })
            .collect()
    }

    pub(crate) fn clear_restored_organization_bindings(&mut self) {
        // Restored shells are new provider sessions, even when public pane IDs match.
        self.clear_organization_bindings(&HashSet::new());
    }

    pub(crate) fn reconcile_organization_bindings(&mut self) {
        if !self
            .state
            .teaser_organization
            .panels
            .iter()
            .any(|panel| matches!(panel.binding, Binding::Terminal { .. }))
        {
            return;
        }
        let available: HashSet<String> = self.organization_terminal_panes();
        self.clear_organization_bindings(&available);
    }

    fn clear_organization_bindings(&mut self, available: &HashSet<String>) {
        let organization: &mut Snapshot = &mut self.state.teaser_organization;
        let mut changed: bool = false;
        for panel in &mut organization.panels {
            if let Binding::Terminal { pane_id } = &panel.binding {
                if !available.contains(pane_id) {
                    panel.binding = Binding::Unbound;
                    changed = true;
                }
            }
        }
        if changed {
            // Revision exhaustion is rejected on writes; cleanup must still remove stale handles.
            organization.revision = organization.revision.saturating_add(1);
            self.organization_changed();
        }
    }

    fn organization_changed(&mut self) {
        self.state.session_dirty = true;
        self.schedule_session_save();
        // This event has no inherited terminal-workspace plugin context.
        self.event_hub.push(EventEnvelope {
            event: EventKind::TeaserOrganizationUpdated,
            data: EventData::TeaserOrganizationUpdated {
                snapshot: self.state.teaser_organization.clone(),
            },
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::schema::{EmptyParams, Method, Request, SuccessResponse};

    fn app() -> App {
        let (_sender, receiver) = tokio::sync::mpsc::unbounded_channel();
        App::new(
            &crate::config::Config::default(),
            crate::app::AppPolicy::TEST,
            None,
            receiver,
            crate::api::EventHub::default(),
        )
    }

    fn apply(app: &mut App, revision: u64, commands: Vec<Command>) -> serde_json::Value {
        serde_json::from_str(&app.handle_api_request(Request {
            id: "test".into(),
            method: Method::TeaserOrganizationApply(Apply {
                expected_revision: revision,
                commands,
            }),
        }))
        .unwrap()
    }

    fn populate(app: &mut App) {
        let fixture: Snapshot = serde_json::from_str(include_str!(
            "../../../../../crates/teaser-core/tests/fixtures/organization.json"
        ))
        .unwrap();
        let commands: Vec<Command> = fixture
            .projects
            .into_iter()
            .map(|project| Command::CreateProject { project })
            .chain(
                fixture
                    .workspaces
                    .into_iter()
                    .map(|workspace| Command::CreateWorkspace { workspace }),
            )
            .chain(
                fixture
                    .panels
                    .into_iter()
                    .filter(|panel| !matches!(panel.binding, Binding::Terminal { .. }))
                    .map(|panel| Command::CreatePanel { panel }),
            )
            .collect();
        assert!(apply(app, 0, commands).get("result").is_some());
    }

    #[test]
    fn organization_snapshot_response_and_event_agree_without_terminal_runtime() {
        let mut app: App = app();
        populate(&mut app);
        assert!(app.state.workspaces.is_empty());
        assert!(app.state.terminals.is_empty());
        let response: SuccessResponse = serde_json::from_str(&app.handle_api_request(Request {
            id: "snapshot".into(),
            method: Method::TeaserOrganizationSnapshot(EmptyParams::default()),
        }))
        .unwrap();
        let ResponseResult::TeaserOrganizationSnapshot { snapshot } = response.result else {
            panic!("wrong response")
        };
        let events: Vec<(u64, EventEnvelope)> = app.event_hub.events_after(0);
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0].1.data,
            EventData::TeaserOrganizationUpdated { snapshot }
        );
        assert_eq!(
            serde_json::to_value(&events[0].1).unwrap()["event"],
            "teaser.organization.updated"
        );
    }

    #[test]
    fn organization_conflicts_and_invalid_bindings_are_atomic() {
        let mut app: App = app();
        populate(&mut app);
        let before: Snapshot = app.state.teaser_organization.clone();
        let sequence: u64 = app.event_hub.current_sequence();
        let command: Command = Command::RebindPanel {
            panel_id: teaser_core::PanelId("panel-notes".into()),
            binding: Binding::Terminal {
                pane_id: "missing".into(),
            },
        };
        assert_eq!(
            apply(&mut app, 0, vec![command.clone()])["error"]["code"],
            "revision_conflict"
        );
        assert_eq!(
            apply(&mut app, 1, vec![command])["error"]["code"],
            "invalid_binding"
        );
        assert_eq!(app.state.teaser_organization, before);
        assert_eq!(app.event_hub.current_sequence(), sequence);
    }

    #[test]
    fn organization_terminal_close_and_restore_clear_bindings_but_delete_does_not_close_pane() {
        let mut app: App = app();
        populate(&mut app);
        app.state.workspaces = vec![crate::workspace::Workspace::test_new("provider")];
        app.state.ensure_test_terminals();
        let pane_id: String = app
            .public_pane_id(0, app.state.workspaces[0].tabs[0].root_pane)
            .unwrap();
        let command: Command = Command::RebindPanel {
            panel_id: teaser_core::PanelId("panel-notes".into()),
            binding: Binding::Terminal { pane_id },
        };
        assert!(apply(&mut app, 1, vec![command.clone()])
            .get("result")
            .is_some());
        app.clear_restored_organization_bindings();
        assert_eq!(app.state.teaser_organization.revision, 3);
        assert_eq!(
            app.state.teaser_organization.panels[0].binding,
            Binding::Unbound
        );
        assert!(apply(&mut app, 3, vec![command.clone()])
            .get("result")
            .is_some());
        app.state.workspaces.clear();
        app.state.session_dirty = true;
        app.sync_session_save_schedule();
        assert_eq!(
            app.state.teaser_organization.panels[0].binding,
            Binding::Unbound
        );
        assert_eq!(app.state.teaser_organization.revision, 5);
        app.state.workspaces = vec![crate::workspace::Workspace::test_new("provider")];
        app.state.ensure_test_terminals();
        let terminals: usize = app.state.terminals.len();
        assert!(apply(
            &mut app,
            5,
            vec![Command::DeletePanel {
                panel_id: teaser_core::PanelId("panel-notes".into())
            }]
        )
        .get("result")
        .is_some());
        assert_eq!(app.state.workspaces.len(), 1);
        assert_eq!(app.state.terminals.len(), terminals);
    }
}
