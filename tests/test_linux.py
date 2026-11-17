import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('pixeldrop', Path(__file__).resolve().parents[1] / 'linux/pixeldrop.py')
picker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(picker)


class PixelTests(unittest.TestCase):
    def test_row_padding_and_clamping(self):
        # Two RGB pixels per row plus two bytes of padding.
        data = bytes([255, 0, 0, 0, 255, 0, 77, 77, 0, 0, 255, 12, 34, 56, 88, 88])
        image = picker.GdkPixbuf.Pixbuf.new_from_bytes(
            picker.GLib.Bytes.new(data), picker.GdkPixbuf.Colorspace.RGB, False, 8, 2, 2, 8)
        self.assertEqual(picker.html_color(picker.rgb_at(image, 1, 1)), '#0C2238')
        self.assertEqual(picker.rgb_at(image, -1, -1), (255, 0, 0))
        self.assertEqual(picker.rgb_at(image, 99, 99), (12, 34, 56))

    def test_alpha_does_not_shift_channels(self):
        image = picker.GdkPixbuf.Pixbuf.new_from_bytes(
            picker.GLib.Bytes.new(bytes([12, 34, 56, 128, 255, 127, 0, 255])),
            picker.GdkPixbuf.Colorspace.RGB, True, 8, 2, 1, 8)
        self.assertEqual(picker.html_color(picker.rgb_at(image, 1, 0)), '#FF7F00')

    def test_escape_before_any_click(self):
        picker.Gtk.init([])
        image = picker.GdkPixbuf.Pixbuf.new(picker.GdkPixbuf.Colorspace.RGB, False, 8, 20, 20)
        image.fill(0x123456FF)
        with patch.object(picker.Gtk, 'main_quit') as quit_loop:
            window = picker.Picker(image)
            self.assertTrue(window.area.is_focus())
            event = picker.Gdk.Event.new(picker.Gdk.EventType.KEY_PRESS)
            event.keyval = picker.Gdk.KEY_Escape
            with patch.object(window, 'copy') as copy:
                self.assertTrue(window.emit('key-press-event', event))
                copy.assert_not_called()
            self.assertFalse(window.get_visible())
            quit_loop.assert_called_once()


if __name__ == '__main__':
    unittest.main()
