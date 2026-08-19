import QtQuick
import QtQuick.Shapes
import qs.Commons
import qs.Ui

// The Shopify bag, rendered natively from its SVG outline as a single
// theme-colored fill (the "S" is a hole in the path), so it stays crisp in
// the bar's tiny icon slot and follows the foreground like every other
// glyph. An optional count badge sits in the top-right corner.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  // Surface the icon sits on; used for the badge outline/text so it reads as
  // a knock-out against the bag.
  property color innerColor: Color.background
  property color badgeColor: color
  property string badgeText: ""

  // The source artwork is 44 wide by 50 tall; iconSize is the height.
  readonly property real viewBoxWidth: 44
  readonly property real viewBoxHeight: 50
  readonly property real unit: root.iconSize / viewBoxHeight

  width: viewBoxWidth * unit
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  Shape {
    id: bag
    width: root.viewBoxWidth
    height: root.viewBoxHeight
    transformOrigin: Item.TopLeft
    scale: root.unit
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    ShapePath {
      fillColor: root.color
      strokeWidth: -1
      fillRule: ShapePath.WindingFill
      PathSvg {
        path: "m30.02 5.94-1.49.44a11.7 11.7 0 0 0-.72-1.76c-1.05-2.01-2.62-3.1-4.46-3.1-.12 0-.25 0-.4.05-.05-.08-.13-.12-.17-.2a3.82 3.82 0 0 0-3.1-1.25c-2.4.08-4.81 1.8-6.74 4.9a19.06 19.06 0 0 0-2.7 7.03c-2.77.84-4.7 1.44-4.73 1.48-1.41.45-1.45.49-1.61 1.81-.24 1-3.9 29.32-3.9 29.32l30.38 5.26V5.86c-.16.04-.28.04-.36.08Zm-7.04 2.17c-1.6.48-3.37 1.05-5.1 1.57a12.4 12.4 0 0 1 2.57-5.02 6.46 6.46 0 0 1 1.73-1.29c.68 1.45.84 3.42.8 4.74Zm-3.25-6.38c.56 0 1.04.12 1.45.36a7.7 7.7 0 0 0-1.9 1.44 14.33 14.33 0 0 0-3.17 6.67l-4.22 1.29c.85-3.82 4.1-9.64 7.84-9.76Zm-4.7 22.08c.16 2.58 6.95 3.14 7.35 9.2.28 4.78-2.53 8.03-6.59 8.27a9.85 9.85 0 0 1-7.6-2.57l1.05-4.41s2.7 2.04 4.86 1.88a1.94 1.94 0 0 0 1.9-2.04c-.2-3.38-5.75-3.18-6.12-8.72-.32-4.62 2.74-9.32 9.49-9.76 2.61-.16 3.94.48 3.94.48l-1.53 5.79s-1.73-.8-3.78-.65c-2.97.2-3.01 2.1-2.97 2.53Zm9.56-16.18c0-1.2-.16-2.93-.72-4.38 1.85.36 2.73 2.41 3.13 3.66-.72.2-1.52.44-2.4.72Zm6.79 42.13L44 46.63 38.54 9.72a.47.47 0 0 0-.45-.4l-3.73-.08-2.98-2.9v43.42Z"
      }
    }
  }

  // Count badge in the top-right corner. In a bar-sized slot a digit cannot
  // resolve, so below ~18px it collapses to a plain dot that just says
  // "more than one".
  readonly property bool badgeShowsText: root.iconSize >= 18

  BorderSurface {
    visible: root.badgeText !== ""
    width: root.badgeShowsText ? Math.max(9, root.iconSize * 0.46) : Math.max(4, root.iconSize * 0.34)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -root.iconSize * (root.badgeShowsText ? 0.16 : 0.12)
    anchors.topMargin: root.badgeShowsText ? -root.iconSize * 0.04 : 0
    borderSpec: Border.flat(root.innerColor, 1)

    Text {
      visible: root.badgeShowsText
      anchors.centerIn: parent
      text: root.badgeText
      color: root.innerColor
      font.family: Style.font.family
      font.pixelSize: Math.max(6, parent.height * 0.7)
      font.bold: true
      renderType: Text.NativeRendering
    }
  }
}
