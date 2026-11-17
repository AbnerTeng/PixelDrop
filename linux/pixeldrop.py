#!/usr/bin/python3
"""Ubuntu GTK screenshot picker; X11 capture or Wayland screenshot portal."""
import os
import sys
import uuid

import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk


def rgb_at(pixbuf, x, y, pixels=None):
    x = min(pixbuf.get_width() - 1, max(0, int(x)))
    y = min(pixbuf.get_height() - 1, max(0, int(y)))
    offset = y * pixbuf.get_rowstride() + x * pixbuf.get_n_channels()
    return tuple((pixels if pixels is not None else pixbuf.get_pixels())[offset:offset + 3])


def html_color(rgb):
    return '#{:02X}{:02X}{:02X}'.format(*rgb)


class Picker(Gtk.Window):
    def __init__(self, image):
        super().__init__(title='PixelDrop — click to copy, Esc to cancel')
        self.image = image
        self.pixels = image.get_pixels()
        self.point = (image.get_width() / 2, image.get_height() / 2)
        self.set_decorated(False)
        self.set_keep_above(True)
        self.area = Gtk.DrawingArea()
        self.area.set_can_focus(True)
        self.add(self.area)
        self.area.add_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.BUTTON_PRESS_MASK)
        self.area.connect('draw', self.draw)
        self.area.connect('motion-notify-event', self.motion)
        self.area.connect('button-press-event', self.click)
        self.connect('key-press-event', self.key)
        self.connect('destroy', lambda *_: Gtk.main_quit())
        self.fullscreen()
        self.show_all()
        self.present()
        self.area.grab_focus()
        self.get_window().set_cursor(Gdk.Cursor.new_for_display(self.get_display(), Gdk.CursorType.CROSSHAIR))

    def position(self, event):
        return (event.x * self.image.get_width() / self.area.get_allocated_width(),
                event.y * self.image.get_height() / self.area.get_allocated_height())

    def motion(self, _widget, event):
        self.point = self.position(event)
        self.area.queue_draw()

    def click(self, _widget, event):
        if event.button == 3:
            self.destroy()
        elif event.button == 1:
            self.point = self.position(event)
            self.copy()
        return True

    def key(self, _widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.destroy()
            return True
        if event.keyval in (Gdk.KEY_Return, Gdk.KEY_space):
            self.copy()
            return True
        return False

    def copy(self):
        value = html_color(rgb_at(self.image, *self.point, pixels=self.pixels))
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_text(value, -1)
        clipboard.set_can_store(None)
        clipboard.store()
        print(value, flush=True)
        self.hide()
        self.notice = Gtk.MessageDialog(
            message_type=Gtk.MessageType.INFO, buttons=Gtk.ButtonsType.OK,
            text='Copied color code ' + value)
        self.notice.set_title('PixelDrop')
        self.notice.connect('response', lambda *_: self.notice.destroy())
        self.notice.connect('destroy', lambda *_: self.destroy())
        self.notice.show_all()
        # Keep clipboard ownership alive while showing the confirmation.
        def dismiss():
            if self.notice.get_visible():
                self.notice.destroy()
            return False
        GLib.timeout_add(3000, dismiss)

    def draw(self, widget, cr):
        width, height = widget.get_allocated_width(), widget.get_allocated_height()
        sx, sy = width / self.image.get_width(), height / self.image.get_height()
        cr.save()
        cr.scale(sx, sy)
        Gdk.cairo_set_source_pixbuf(cr, self.image, 0, 0)
        cr.get_source().set_filter(0)  # cairo.FILTER_FAST: preserve pixel boundaries
        cr.paint()
        cr.restore()
        px, py = self.point
        cx, cy = px * sx, py * sy
        left, top = max(0, min(cx + 25, width - 180)), max(0, min(cy + 25, height - 190))
        cr.set_source_rgba(.06, .06, .06, .97)
        cr.rectangle(left, top, 180, 190)
        cr.fill()
        for y in range(11):
            for x in range(11):
                rgb = rgb_at(self.image, int(px) + x - 5, int(py) + y - 5, self.pixels)
                cr.set_source_rgb(*(v / 255 for v in rgb))
                cr.rectangle(left + 24 + x * 12, top + 10 + y * 12, 12, 12)
                cr.fill()
        cr.set_source_rgb(1, 1, 1)
        cr.set_line_width(2)
        cr.rectangle(left + 84, top + 70, 12, 12)
        cr.stroke()
        cr.select_font_face('monospace')
        cr.set_font_size(20)
        cr.move_to(left + 24, top + 163)
        cr.show_text(html_color(rgb_at(self.image, px, py, self.pixels)))
        cr.set_font_size(11)
        cr.move_to(left + 14, top + 182)
        cr.show_text('Click to copy · Esc exits')
        return False


class Capture:
    def __init__(self):
        self.picker = None
        self.bus = None
        self.subscription = None

    def fail(self, message):
        dialog = Gtk.MessageDialog(message_type=Gtk.MessageType.ERROR, buttons=Gtk.ButtonsType.CLOSE,
                                   text='PixelDrop could not capture the screen')
        dialog.format_secondary_text(str(message))
        dialog.run()
        dialog.destroy()
        Gtk.main_quit()

    def start(self):
        if os.environ.get('XDG_SESSION_TYPE') != 'wayland' and not os.environ.get('WAYLAND_DISPLAY'):
            root = Gdk.get_default_root_window()
            image = Gdk.pixbuf_get_from_window(root, 0, 0, root.get_width(), root.get_height()) if root else None
            if image:
                self.picker = Picker(image)
            else:
                self.fail('No screenshot was returned by the X11 server.')
            return False
        try:
            self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            token = 'pixeldrop_' + uuid.uuid4().hex
            sender = self.bus.get_unique_name()[1:].replace('.', '_')
            path = '/org/freedesktop/portal/desktop/request/' + sender + '/' + token
            self.subscription = self.bus.signal_subscribe(
                'org.freedesktop.portal.Desktop', 'org.freedesktop.portal.Request',
                'Response', path, None, Gio.DBusSignalFlags.NONE, self.response, None)
            options = {'handle_token': GLib.Variant('s', token), 'interactive': GLib.Variant('b', False)}
            self.bus.call('org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop',
                          'org.freedesktop.portal.Screenshot', 'Screenshot',
                          GLib.Variant('(sa{sv})', ('', options)), GLib.VariantType.new('(o)'),
                          Gio.DBusCallFlags.NONE, -1, None, self.requested, None)
        except Exception as error:
            self.fail(error)
        return False

    def requested(self, connection, result, _data):
        try:
            connection.call_finish(result)
        except Exception as error:
            self.fail(error)

    def response(self, _connection, _sender, _path, _interface, _signal, parameters, _data):
        self.bus.signal_unsubscribe(self.subscription)
        response, results = parameters.unpack()
        if response != 0:
            Gtk.main_quit()  # Portal cancellation must not show another dialog.
            return
        try:
            file = Gio.File.new_for_uri(results['uri'])
            stream = file.read(None)
            try:
                image = GdkPixbuf.Pixbuf.new_from_stream(stream, None)
            finally:
                stream.close(None)
            self.picker = Picker(image)
        except Exception as error:
            self.fail(error)


def main():
    Gtk.init(sys.argv)
    capture = Capture()
    GLib.idle_add(capture.start)
    Gtk.main()


if __name__ == '__main__':
    main()
