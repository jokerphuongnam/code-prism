import { AnimatePresence, motion } from "framer-motion";
import type { FilePreview } from "../protocol";

interface HoveredNodeInfo {
  id: string;
  name: string;
  flavor: string;
  subKind: string | null;
  isStatic: boolean;
  isGlobal: boolean;
  isModule: boolean;
  parentId: string | null;
  sourceFile: string;
  memberCount: number | null;
  color: string;
}

interface NodeDetailCardProps {
  node: HoveredNodeInfo | null;
  preview: FilePreview | null;
  position: { x: number; y: number } | null;
  containerWidth: number;
  containerHeight: number;
}

const FLAVOR_ICONS: Record<string, string> = {
  struct: "\u25A0",
  class: "\u25CF",
  enum: "\u25C6",
  actor: "\u25B2",
  protocol: "\u25CE",
  function: "\u0192",
  variable: "x",
  initializer: "\u2295",
  macro: "\u26A1",
  resource: "\u{1F4C1}",
  module: "\u{1F4E6}",
  file: "\u{1F4C4}",
};

const FLAVOR_LABELS: Record<string, string> = {
  struct: "Struct",
  class: "Class",
  enum: "Enum",
  actor: "Actor",
  protocol: "Protocol",
  function: "Function",
  variable: "Variable",
  initializer: "Initializer",
  macro: "Macro",
  resource: "Resource",
  module: "Module",
  file: "File",
  image_set: "Image Asset",
  color_set: "Color Asset",
  data_set: "Data Asset",
  asset_catalog: "Asset Catalog",
  json_file: "JSON",
  plist_file: "Property List",
  markdown_file: "Markdown",
  strings_file: "Strings",
  localization: "Localization",
};

export function NodeDetailCard({ node, preview, position, containerWidth, containerHeight }: NodeDetailCardProps) {
  if (!position) return null;

  const cardWidth = 240;
  const cardMaxHeight = 280;
  const left = Math.min(position.x + 20, containerWidth - cardWidth - 12);
  const top = Math.min(Math.max(position.y - 40, 8), containerHeight - cardMaxHeight - 12);

  return (
    <AnimatePresence mode="wait">
      {node && (
        <motion.div
          key={node.id}
          initial={{ opacity: 0, scale: 0.92, y: 6 }}
          animate={{ opacity: 1, scale: 1, y: 0 }}
          exit={{ opacity: 0, scale: 0.95, y: 4 }}
          transition={{ duration: 0.15, ease: "easeOut" }}
          style={{ ...cardStyles.card, left, top }}
        >
          <div style={cardStyles.header}>
            <span style={{ ...cardStyles.icon, color: node.color }}>
              {FLAVOR_ICONS[node.flavor] ?? "\u25CF"}
            </span>
            <div style={cardStyles.headerText}>
              <div style={cardStyles.name}>{node.name}</div>
              <div style={cardStyles.type}>
                {FLAVOR_LABELS[node.flavor] ?? node.flavor}
                {node.subKind && ` (${node.subKind})`}
                {node.isStatic && " \u2022 static"}
                {node.isGlobal && " \u2022 global"}
              </div>
            </div>
          </div>

          <div style={cardStyles.body}>
            <AnimatePresence mode="wait">
              {preview && preview.nodeId === node.id ? (
                <motion.div
                  key={`preview-${node.id}`}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0 }}
                  transition={{ duration: 0.12 }}
                >
                  {preview.previewType === "image" && (
                    <img src={preview.data} alt={preview.fileName} style={cardStyles.image} />
                  )}
                  {preview.previewType === "text" && (
                    <pre style={cardStyles.code}>{preview.data}</pre>
                  )}
                  {preview.previewType === "none" && node.memberCount && node.memberCount > 0 && (
                    <div style={cardStyles.memberInfo}>
                      {node.memberCount} members
                    </div>
                  )}
                </motion.div>
              ) : (
                <motion.div
                  key={`info-${node.id}`}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  exit={{ opacity: 0 }}
                  transition={{ duration: 0.12 }}
                >
                  {node.memberCount && node.memberCount > 0 ? (
                    <div style={cardStyles.memberInfo}>
                      {node.memberCount} members
                    </div>
                  ) : (
                    <div style={cardStyles.placeholder}>
                      {node.parentId ? `in ${node.parentId}` : "top-level"}
                    </div>
                  )}
                </motion.div>
              )}
            </AnimatePresence>
          </div>

          <div style={cardStyles.footer}>
            <span style={cardStyles.footerFile}>{node.sourceFile}</span>
          </div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

const cardStyles: Record<string, React.CSSProperties> = {
  card: {
    position: "absolute",
    zIndex: 30,
    width: 240,
    background: "rgba(30, 30, 30, 0.85)",
    backdropFilter: "blur(16px)",
    WebkitBackdropFilter: "blur(16px)",
    border: "1px solid rgba(255, 255, 255, 0.08)",
    borderRadius: 10,
    overflow: "hidden",
    pointerEvents: "none",
    boxShadow: "0 8px 32px rgba(0, 0, 0, 0.5), 0 0 1px rgba(255, 255, 255, 0.1)",
  },
  header: {
    display: "flex",
    alignItems: "center",
    gap: 10,
    padding: "10px 12px 8px",
    borderBottom: "1px solid rgba(255, 255, 255, 0.06)",
  },
  icon: {
    fontSize: "1.3em",
    flexShrink: 0,
    width: 24,
    textAlign: "center" as const,
  },
  headerText: {
    minWidth: 0,
    flex: 1,
  },
  name: {
    fontSize: "0.85em",
    fontWeight: 600,
    color: "rgba(255, 255, 255, 0.92)",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
  },
  type: {
    fontSize: "0.65em",
    color: "rgba(255, 255, 255, 0.45)",
    marginTop: 1,
  },
  body: {
    padding: "8px 12px",
    minHeight: 40,
  },
  image: {
    width: "100%",
    maxHeight: 160,
    objectFit: "contain" as const,
    borderRadius: 6,
    background: "rgba(255, 255, 255, 0.03)",
    display: "block",
  },
  code: {
    fontSize: "0.6em",
    fontFamily: "var(--vscode-editor-font-family, monospace)",
    color: "rgba(255, 255, 255, 0.7)",
    background: "rgba(0, 0, 0, 0.3)",
    borderRadius: 6,
    padding: 8,
    margin: 0,
    maxHeight: 140,
    overflow: "hidden",
    whiteSpace: "pre-wrap" as const,
    wordBreak: "break-word" as const,
    lineHeight: 1.5,
  },
  memberInfo: {
    fontSize: "0.75em",
    color: "rgba(255, 255, 255, 0.5)",
    textAlign: "center" as const,
    padding: "8px 0",
  },
  placeholder: {
    fontSize: "0.7em",
    color: "rgba(255, 255, 255, 0.3)",
    textAlign: "center" as const,
    padding: "4px 0",
  },
  footer: {
    padding: "6px 12px 8px",
    borderTop: "1px solid rgba(255, 255, 255, 0.06)",
  },
  footerFile: {
    fontSize: "0.6em",
    color: "rgba(255, 255, 255, 0.3)",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap" as const,
    display: "block",
  },
};
