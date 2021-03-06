public class SourceFileView : Gtk.ScrolledWindow
{

    static construct
    {
        string font_name = new GLib.Settings( "org.gnome.desktop.interface" ).get_string( "monospace-font-name" );
        DEFAULT_FONT = Pango.FontDescription.from_string( font_name );

        LANG_LATEX   = Gtk.SourceLanguageManager.get_default().get_language( "latex"  );
        LANG_BIBTEX  = Gtk.SourceLanguageManager.get_default().get_language( "bibtex" );
        STYLE_SCHEME = Gtk.SourceStyleSchemeManager.get_default().get_scheme( "solarized-light" );
    }

    private static Pango.FontDescription DEFAULT_FONT;
    private static Gtk.SourceLanguage    LANG_LATEX;
    private static Gtk.SourceLanguage    LANG_BIBTEX;
    private static Gtk.SourceStyleScheme STYLE_SCHEME;

    public weak SourceFileManager.SourceFile file { public get; private set; }
    public SourceStructure.SimpleNode structure { public get; private set; default = new SourceStructure.SimpleNode(); }

    public weak Editor editor { get; private set; }
    public Gtk.SourceView text_view { get; private set; }
    private static Gdk.Cursor default_cursor;

    public Gtk.SourceBuffer buffer { get; private set; }

    public static string[] available_style_schemes
    {
        get
        {
            return Gtk.SourceStyleSchemeManager.get_default().get_scheme_ids();
        }
    }

    public int current_line
    {
        set
        {
            Gtk.TextIter iter;
            buffer.get_iter_at_mark( out iter, buffer.get_insert() );
            iter.set_line( value );
            buffer.place_cursor( iter );
            text_view.scroll_to_iter( iter, 0, true, 0.5, 0.5 );
        }
        get
        {
            Gtk.TextIter iter;
            buffer.get_iter_at_mark( out iter, buffer.get_insert() );
            return iter.get_line();
        }
    }

    private SourcePartitioning partitioning;

    private class Partition : SourcePartitioning.Partition
    {
        private SourceStructure.SimpleNode partition_root = new SourceStructure.SimpleNode();
        private SourceFileView view;

        internal Partition( SourceFileView view )
        {
            this.view = view;
            view.structure.add_child( partition_root );
        }

        /**
         * Removes this partition's nodes from the source structure graph.
         */
        ~Partition()
        {
            partition_root.remove_from_parents();
        }

        /**
         * Clears this partitions's source structure graph.
         */
        private void clear()
        {
            partition_root.remove_all_children();
        }

        private SourceAnalyzer.StringHandler create_leafs( SourceStructure.Feature feature )
        {
            return ( value ) =>
            {
                var leaf = new SourceStructure.Node();
                leaf.features[ feature ] = value;
                partition_root.add_child( leaf );
            };
        }

        private void handle_file_reference( string path, SourceAnalyzer.FileReferenceType type )
        {
            var ref_node = new SourceStructure.FileReferenceNode( view, path, type );
            partition_root.add_child( ref_node );
            ref_node.resolve();
        }

        private void handle_package_reference( string package_name )
        {
            if( package_name.length < 2 ) return;
            var pkg_node = new SourceStructure.UsePackageNode( view, package_name );
            partition_root.add_child( pkg_node );
            pkg_node.update( true );
        }
       
        /**
         * Rebuilds the source structure graph of this partition.
         */ 
        public override void update()
        {
            clear();
            var analyzer = SourceAnalyzer.instance;
            var text = get_text( view.buffer );

            if( view.mode == Mode.UNKNOWN || view.mode == Mode.BIBTEX )
            {
                analyzer.find_bib_entries( text, create_leafs( SourceStructure.Feature.BIB_ENTRY ) );
            }
            if( view.mode == Mode.UNKNOWN || view.mode == Mode.LATEX )
            {
                analyzer.find_labels            ( text, create_leafs( SourceStructure.Feature.LABEL   ) );
                analyzer.find_commands          ( text, create_leafs( SourceStructure.Feature.COMMAND ) );
                analyzer.find_file_references   ( text, handle_file_reference );
                analyzer.find_package_references( text, handle_package_reference );
            }
        }

        public override void split( SourcePartitioning.Partition successor )
        {
            successor.update();
            this.update();
        }

        public override void merge( SourcePartitioning.Partition successor )
        {
        }
    }

    #if DEBUG
    public static uint _debug_instance_counter = 0;
    #endif

    private void apply_settings()
    {
        var settings = Athena.instance.settings;

        text_view.tab_width = settings.indent_width;
        text_view.auto_indent = settings.auto_indent;
        text_view.insert_spaces_instead_of_tabs = settings.whitespaces;
    }

    public SourceFileView( Editor editor, SourceFileManager.SourceFile file )
    {
        #if DEBUG
        ++_debug_instance_counter;
        #endif

        this.editor = editor;
        this.file = file;

        buffer = new Gtk.SourceBuffer.with_language( LANG_LATEX );
        buffer.set_style_scheme( STYLE_SCHEME );
        update_buffer_language();

        text_view = new Gtk.SourceView();
        text_view.buffer = buffer;
	text_view.show_line_marks = true;
	text_view.highlight_current_line = true;
        text_view.override_font( DEFAULT_FONT );
        text_view.set_show_line_numbers( true );
        text_view.indent_on_tab = true;
        text_view.set_wrap_mode( Gtk.WrapMode.WORD_CHAR );

        apply_settings();
        weak SourceFileView weak_this = this;
        Athena.instance.settings.changed.connect( weak_this.apply_settings );

        partitioning = new SourcePartitioning( buffer, () => { return new Partition( this ); } );
        text_view.get_completion().add_provider( editor.    ref_completion_provider );
        text_view.get_completion().add_provider( editor.  eqref_completion_provider );
        text_view.get_completion().add_provider( editor.   cite_completion_provider );
        text_view.get_completion().add_provider( editor.  citep_completion_provider );
        text_view.get_completion().add_provider( editor.  citet_completion_provider );
        text_view.get_completion().add_provider( editor.command_completion_provider );

        this.add( text_view );
        this.grab_focus.connect_after( () => { text_view.grab_focus(); } );

        if( default_cursor == null ) default_cursor = new Gdk.Cursor( Gdk.CursorType.XTERM );

        editor.file_saved.connect( weak_this.handle_file_saved );
        Athena.instance.change_cursor.connect( weak_this.change_cursor );

        /* Wait for the control to return to the event loop before installing
         * the buffer callbacks, to avoid flagging that file view as modified
         * e.g. after something is loaded into the buffer.
         */
        Timeout.add( 0, () =>
            {
                buffer.changed.connect( weak_this.set_modified_flag );
                return GLib.Source.REMOVE;
            }
        );
    }

    ~SourceFileView()
    {
        #if DEBUG
        --_debug_instance_counter;
        #endif
    }

    private void change_cursor( Gdk.Cursor? cursor )
    {
        var window = text_view.get_window( Gtk.TextWindowType.TEXT );
        if( window != null) window.set_cursor( cursor ?? default_cursor );
    }

    private void set_modified_flag()
    {
        editor.session.files.set_flags( file.position, Session.FLAGS_MODIFIED );
    }

    private void handle_file_saved( SourceFileManager.SourceFile file )
    {
        if( file == this.file )
        {
            partitioning.partition( SourcePartitioning.DEFAULT_LINES_PER_PARTITION, true );
            update_buffer_language();
        }
    }

    public override void destroy()
    {
        structure.remove_from_parents();
        partitioning = null;
        base.destroy();
    }

    /**
     * Returns the absolute counterpart if `path` is relative, or just `path` if it already is absolute.
     *
     * If `path` isn't absolute but its resolution fails, then `null` is returned.
     */
    public string? resolve_path( string path, SourceAnalyzer.FileReferenceType path_type )
    {
        if( ( path_type == SourceAnalyzer.FileReferenceType.SUB_REFERENCE )
         || ( path_type == SourceAnalyzer.FileReferenceType.UNKNOWN && !Path.is_absolute( path ) ) )
        {
            SourceFileManager.SourceFile? parent = null;
            if( editor.build_input != null ) parent = editor.build_input;
            else
            {
                if( this.file.path == null ) return null;
                else parent = this.file;
            }

            File root_dir = File.new_for_path( parent.path ).get_parent();
            var abs_path = root_dir.resolve_relative_path( path ).get_path();
            if( abs_path == null ) return null; // i.e. the path resolution failed
            return abs_path;
        }
        else
        {
            return path;
        }
    }

    public enum Mode { UNKNOWN, LATEX, BIBTEX }

    public Mode mode
    {
        get
        {
            if( file.path == null ) return Mode.UNKNOWN;
            var file_path_lower = file.path.down();

            if( file_path_lower.has_suffix( ".tex" ) )
            {
                return Mode.LATEX;
            }
            else
            if( file_path_lower.has_suffix( ".bib" ) )
            {
                return Mode.BIBTEX;
            }
            else
            {
                return Mode.UNKNOWN;
            }
        }
    }

    private void update_buffer_language()
    {
        switch( mode )
        {

        case Mode.UNKNOWN:
        case Mode.LATEX:
            buffer.language = LANG_LATEX;
            break;

        case Mode.BIBTEX:
            buffer.language = LANG_BIBTEX;
            break;

        default:
            assert_not_reached();

        }
    }

    public double view_position
    {
        get
        {
            var vadj = get_vadjustment();
            return ( vadj.value + vadj.page_size / 2 ) / vadj.upper;
        }
        set
        {
            var vadj = get_vadjustment();
            vadj.value = value * vadj.upper - vadj.page_size / 2;
            vadj.value_changed();
        }
    }

    public string get_selection()
    {
        Gtk.TextIter start;
        Gtk.TextIter end;
        if( buffer.get_selection_bounds( out start, out end ) ) return buffer.get_text( start, end, true );
        else return "";
    }

}
