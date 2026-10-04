//! Pure, revisioned logical organization. No process, placement, or focus authority.
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

macro_rules! identifier {
    ($name:ident) => {
        #[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize, JsonSchema)]
        #[serde(transparent)]
        pub struct $name(pub String);
    };
}
identifier!(ProjectId);
identifier!(WorkspaceId);
identifier!(PanelId);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Project {
    pub id: ProjectId,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TaskReference {
    pub provider: String,
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub project_id: ProjectId,
    pub name: String,
    pub task: Option<TaskReference>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Binding {
    Unbound,
    Terminal { pane_id: String },
    App { bundle_id: String },
    Notes { document_id: String },
}

/// Relative layout preference, never terminal cells or native pixel geometry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SizeProfile {
    pub name: String,
    pub min_width: u32,
    pub min_height: u32,
    pub preferred_width: u32,
    pub preferred_height: u32,
    pub growth_weight: f64,
    pub preferred_aspect_ratio: AspectRatio,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AspectRatio {
    pub minimum: f64,
    pub maximum: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Panel {
    pub id: PanelId,
    pub workspace_id: WorkspaceId,
    pub title: String,
    pub kind: String,
    pub binding: Binding,
    pub size_profile: SizeProfile,
}

#[derive(Debug, Default, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Snapshot {
    pub revision: u64,
    pub projects: Vec<Project>,
    pub workspaces: Vec<Workspace>,
    pub panels: Vec<Panel>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Apply {
    pub expected_revision: u64,
    pub commands: Vec<Command>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Command {
    CreateProject {
        project: Project,
    },
    RenameProject {
        project_id: ProjectId,
        name: String,
    },
    DeleteProject {
        project_id: ProjectId,
    },
    CreateWorkspace {
        workspace: Workspace,
    },
    RenameWorkspace {
        workspace_id: WorkspaceId,
        name: String,
    },
    DeleteWorkspace {
        workspace_id: WorkspaceId,
    },
    SetWorkspaceTask {
        workspace_id: WorkspaceId,
        task: Option<TaskReference>,
    },
    CreatePanel {
        panel: Panel,
    },
    RenamePanel {
        panel_id: PanelId,
        title: String,
    },
    SetPanelKind {
        panel_id: PanelId,
        kind: String,
    },
    DeletePanel {
        panel_id: PanelId,
    },
    RegroupPanel {
        panel_id: PanelId,
        workspace_id: WorkspaceId,
    },
    RebindPanel {
        panel_id: PanelId,
        binding: Binding,
    },
    SetPanelSizeProfile {
        panel_id: PanelId,
        size_profile: SizeProfile,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    RevisionConflict,
    InvalidId,
    DuplicateId,
    UnknownObject,
    InvalidProfile,
    InvalidValue,
    ObjectNotEmpty,
    RevisionExhausted,
    LimitExceeded,
}

impl Error {
    pub fn code(self) -> &'static str {
        match self {
            Self::RevisionConflict => "revision_conflict",
            Self::InvalidId => "invalid_id",
            Self::DuplicateId => "duplicate_id",
            Self::UnknownObject => "unknown_object",
            Self::InvalidProfile => "invalid_profile",
            Self::InvalidValue => "invalid_value",
            Self::ObjectNotEmpty => "object_not_empty",
            Self::RevisionExhausted => "revision_exhausted",
            Self::LimitExceeded => "limit_exceeded",
        }
    }
}

impl Snapshot {
    /// Prepare a complete next value. The caller commits only after provider validation.
    pub fn applying(&self, request: &Apply) -> Result<Self, Error> {
        if request.expected_revision != self.revision {
            return Err(Error::RevisionConflict);
        }
        if request.commands.is_empty() {
            return Err(Error::InvalidValue);
        }
        if request.commands.len() > 256 {
            return Err(Error::LimitExceeded);
        }
        let mut next: Self = self.clone();
        for command in &request.commands {
            next.execute(command)?;
            next.validate()?;
        }
        next.revision = self
            .revision
            .checked_add(1)
            .ok_or(Error::RevisionExhausted)?;
        Ok(next)
    }

    pub fn validate(&self) -> Result<(), Error> {
        if self.projects.len() + self.workspaces.len() + self.panels.len() > 4096 {
            return Err(Error::LimitExceeded);
        }
        let mut ids: HashSet<&str> = HashSet::new();
        for id in self
            .projects
            .iter()
            .map(|item| item.id.0.as_str())
            .chain(self.workspaces.iter().map(|item| item.id.0.as_str()))
            .chain(self.panels.iter().map(|item| item.id.0.as_str()))
        {
            if id.is_empty()
                || id.len() > 128
                || !id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_.:".contains(&byte))
            {
                return Err(Error::InvalidId);
            }
            if !ids.insert(id) {
                return Err(Error::DuplicateId);
            }
        }
        for project in &self.projects {
            valid_text(&project.name)?;
        }
        for workspace in &self.workspaces {
            valid_text(&workspace.name)?;
            if !self
                .projects
                .iter()
                .any(|project| project.id == workspace.project_id)
            {
                return Err(Error::UnknownObject);
            }
            if let Some(task) = &workspace.task {
                valid_text(&task.provider)?;
                valid_text(&task.id)?;
            }
        }
        for panel in &self.panels {
            valid_text(&panel.title)?;
            valid_text(&panel.kind)?;
            if !self
                .workspaces
                .iter()
                .any(|workspace| workspace.id == panel.workspace_id)
            {
                return Err(Error::UnknownObject);
            }
            match &panel.binding {
                Binding::Unbound => {}
                Binding::Terminal { pane_id } => valid_text(pane_id)?,
                Binding::App { bundle_id } => valid_text(bundle_id)?,
                Binding::Notes { document_id } => valid_text(document_id)?,
            }
            let profile: &SizeProfile = &panel.size_profile;
            if valid_text(&profile.name).is_err()
                || profile.min_width == 0
                || profile.min_height == 0
                || profile.preferred_width < profile.min_width
                || profile.preferred_height < profile.min_height
                || profile.preferred_width > 1_000_000
                || profile.preferred_height > 1_000_000
                || !profile.growth_weight.is_finite()
                || profile.growth_weight <= 0.0
                || profile.growth_weight > 1_000_000.0
                || !profile.preferred_aspect_ratio.minimum.is_finite()
                || !profile.preferred_aspect_ratio.maximum.is_finite()
                || profile.preferred_aspect_ratio.minimum <= 0.0
                || profile.preferred_aspect_ratio.maximum < profile.preferred_aspect_ratio.minimum
            {
                return Err(Error::InvalidProfile);
            }
        }
        Ok(())
    }

    fn execute(&mut self, command: &Command) -> Result<(), Error> {
        match command {
            Command::CreateProject { project } => self.projects.push(project.clone()),
            Command::RenameProject { project_id, name } => {
                self.projects
                    .iter_mut()
                    .find(|item| item.id == *project_id)
                    .ok_or(Error::UnknownObject)?
                    .name = name.clone();
            }
            Command::DeleteProject { project_id } => {
                if self
                    .workspaces
                    .iter()
                    .any(|item| item.project_id == *project_id)
                {
                    return Err(Error::ObjectNotEmpty);
                }
                let index: usize = self
                    .projects
                    .iter()
                    .position(|item| item.id == *project_id)
                    .ok_or(Error::UnknownObject)?;
                self.projects.remove(index);
            }
            Command::CreateWorkspace { workspace } => self.workspaces.push(workspace.clone()),
            Command::RenameWorkspace { workspace_id, name } => {
                self.workspace_mut(workspace_id)?.name = name.clone()
            }
            Command::SetWorkspaceTask { workspace_id, task } => {
                self.workspace_mut(workspace_id)?.task = task.clone()
            }
            Command::DeleteWorkspace { workspace_id } => {
                if self
                    .panels
                    .iter()
                    .any(|item| item.workspace_id == *workspace_id)
                {
                    return Err(Error::ObjectNotEmpty);
                }
                let index: usize = self
                    .workspaces
                    .iter()
                    .position(|item| item.id == *workspace_id)
                    .ok_or(Error::UnknownObject)?;
                self.workspaces.remove(index);
            }
            Command::CreatePanel { panel } => self.panels.push(panel.clone()),
            Command::RenamePanel { panel_id, title } => {
                self.panel_mut(panel_id)?.title = title.clone()
            }
            Command::SetPanelKind { panel_id, kind } => {
                self.panel_mut(panel_id)?.kind = kind.clone()
            }
            Command::DeletePanel { panel_id } => {
                let index: usize = self
                    .panels
                    .iter()
                    .position(|item| item.id == *panel_id)
                    .ok_or(Error::UnknownObject)?;
                self.panels.remove(index);
            }
            Command::RegroupPanel {
                panel_id,
                workspace_id,
            } => self.panel_mut(panel_id)?.workspace_id = workspace_id.clone(),
            Command::RebindPanel { panel_id, binding } => {
                self.panel_mut(panel_id)?.binding = binding.clone()
            }
            Command::SetPanelSizeProfile {
                panel_id,
                size_profile,
            } => self.panel_mut(panel_id)?.size_profile = size_profile.clone(),
        }
        Ok(())
    }

    fn workspace_mut(&mut self, id: &WorkspaceId) -> Result<&mut Workspace, Error> {
        self.workspaces
            .iter_mut()
            .find(|item| item.id == *id)
            .ok_or(Error::UnknownObject)
    }

    fn panel_mut(&mut self, id: &PanelId) -> Result<&mut Panel, Error> {
        self.panels
            .iter_mut()
            .find(|item| item.id == *id)
            .ok_or(Error::UnknownObject)
    }
}

fn valid_text(value: &str) -> Result<(), Error> {
    if value.trim().is_empty() || value.len() > 4096 || value.chars().any(char::is_control) {
        Err(Error::InvalidValue)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_native_fixture_round_trips() {
        let value: serde_json::Value =
            serde_json::from_str(include_str!("../tests/fixtures/organization.json")).unwrap();
        let snapshot: Snapshot = serde_json::from_value(value.clone()).unwrap();
        snapshot.validate().unwrap();
        assert_eq!(serde_json::to_value(snapshot).unwrap(), value);
    }

    fn fixture() -> Snapshot {
        serde_json::from_value(serde_json::json!({
            "revision": 5,
            "projects": [{"id":"project", "name":"Teaser"}],
            "workspaces": [
                {"id":"one", "project_id":"project", "name":"One", "task":null},
                {"id":"two", "project_id":"project", "name":"Two", "task":{"provider":"linear", "id":"P-623"}}
            ],
            "panels": [{"id":"panel", "workspace_id":"one", "title":"Notes", "kind":"notes",
                "binding":{"type":"notes", "document_id":"doc"},
                "size_profile":{"name":"notes", "min_width":1, "min_height":1, "preferred_width":3,
                    "preferred_height":2, "growth_weight":1.0, "preferred_aspect_ratio":{"minimum":1.0,"maximum":2.0}}}]
        })).unwrap()
    }

    #[test]
    fn regroup_and_rebind_preserve_identity_and_other_fields() {
        let original: Snapshot = fixture();
        let next: Snapshot = original
            .applying(&Apply {
                expected_revision: 5,
                commands: vec![
                    Command::RegroupPanel {
                        panel_id: PanelId("panel".into()),
                        workspace_id: WorkspaceId("two".into()),
                    },
                    Command::RebindPanel {
                        panel_id: PanelId("panel".into()),
                        binding: Binding::App {
                            bundle_id: "com.example.app".into(),
                        },
                    },
                    Command::SetPanelKind {
                        panel_id: PanelId("panel".into()),
                        kind: "custom-kind".into(),
                    },
                ],
            })
            .unwrap();
        assert_eq!(next.revision, 6);
        assert_eq!(next.panels[0].id, original.panels[0].id);
        assert_eq!(next.panels[0].workspace_id.0, "two");
        assert_eq!(next.panels[0].size_profile, original.panels[0].size_profile);
        assert_eq!(original.panels[0].workspace_id.0, "one");
    }

    #[test]
    fn failed_batch_and_stale_revision_leave_original_unchanged() {
        let original: Snapshot = fixture();
        let copy: Snapshot = original.clone();
        let mut request: Apply = Apply {
            expected_revision: 4,
            commands: vec![Command::RenameProject {
                project_id: ProjectId("project".into()),
                name: "New".into(),
            }],
        };
        assert_eq!(original.applying(&request), Err(Error::RevisionConflict));
        request.expected_revision = 5;
        request.commands.push(Command::DeletePanel {
            panel_id: PanelId("missing".into()),
        });
        assert_eq!(original.applying(&request), Err(Error::UnknownObject));
        assert_eq!(original, copy);
    }

    #[test]
    fn validates_ids_profiles_and_references() {
        let original: Snapshot = fixture();
        original.validate().unwrap();
        let mut bad: Snapshot = original.clone();
        bad.projects[0].id.0 = "bad id".into();
        assert_eq!(bad.validate(), Err(Error::InvalidId));
        bad = original.clone();
        bad.panels[0].id.0 = "project".into();
        assert_eq!(bad.validate(), Err(Error::DuplicateId));
        bad = original.clone();
        bad.panels[0].workspace_id.0 = "missing".into();
        assert_eq!(bad.validate(), Err(Error::UnknownObject));
        bad = original.clone();
        bad.panels[0].size_profile.growth_weight = f64::NAN;
        assert_eq!(bad.validate(), Err(Error::InvalidProfile));
        bad = original;
        bad.panels[0].size_profile.preferred_aspect_ratio.maximum = 0.5;
        assert_eq!(bad.validate(), Err(Error::InvalidProfile));
    }

    #[test]
    fn delete_requires_explicit_child_removal_and_only_changes_logical_graph() {
        let original: Snapshot = fixture();
        let mut request: Apply = Apply {
            expected_revision: 5,
            commands: vec![Command::DeleteWorkspace {
                workspace_id: WorkspaceId("one".into()),
            }],
        };
        assert_eq!(original.applying(&request), Err(Error::ObjectNotEmpty));
        request.commands.insert(
            0,
            Command::DeletePanel {
                panel_id: PanelId("panel".into()),
            },
        );
        assert!(original.applying(&request).unwrap().panels.is_empty());
    }

    #[test]
    fn bounded_requests_and_unknown_fields_fail_closed() {
        let original: Snapshot = fixture();
        assert_eq!(
            original.applying(&Apply {
                expected_revision: 5,
                commands: Vec::new()
            }),
            Err(Error::InvalidValue)
        );
        let command: Command = Command::DeletePanel {
            panel_id: PanelId("panel".into()),
        };
        assert_eq!(
            original.applying(&Apply {
                expected_revision: 5,
                commands: vec![command; 257]
            }),
            Err(Error::LimitExceeded)
        );
        assert!(serde_json::from_str::<Command>(r#"{"type":"future_command"}"#).is_err());
        assert!(
            serde_json::from_str::<Command>(
                r#"{"type":"delete_panel","panel_id":"panel","force":true}"#
            )
            .is_err()
        );
    }
}
