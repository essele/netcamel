#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <string.h>
#include <termios.h>
#include <time.h>
#include <poll.h>
#include <curses.h>
#include <term.h>
#include <unistd.h>
#include <sys/ioctl.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>


// For saving and restoring our termios...
struct termios	old_termio, new_termio;

// Keep track of our cursor position
int				width;		// terminal width
int				height;		// terminal height
int				col;		// current column
int				row;		// current row
int				scol;		// saved column
int				srow;		// saved row

char	*line;
char	*syntax;

char	*sample = "blah blah";
int		line_len;


int		have_multi_move = 0;

int		function_index;


/*
 * Table for reading termcap keys
 */
struct {
	char	*name;
	char	*data;
	int		len;
	int		rc;
} ti_keys[] = {
		// The terminfo database is wrong for cursors??
		{ "kcuu1", "\033[A", 3, KEY_UP },
		{ "kcud1", "\033[B", 3, KEY_DOWN },
		{ "kcub1", "\033[D", 3, KEY_LEFT },
		{ "kcuf1", "\033[C", 3, KEY_RIGHT },

		// Get them defined ones anyway...
		{ "kcuu1", NULL, 0, KEY_UP },
		{ "kcud1", NULL, 0, KEY_DOWN },
		{ "kcub1", NULL, 0, KEY_LEFT },
		{ "kcuf1", NULL, 0, KEY_RIGHT },
		{ "kdch1", NULL, 0, KEY_DC },

		// End the list...
		{ NULL, NULL, 0 }
};

static int shortest_key_data = 999;
static int longest_key_data = 0;


void remove_char_at(int i) {
	int movesize = line_len - i;	// includes 0 term
	memmove(line+i, line+i+1, movesize);
	line_len--;
}
void insert_char_at(int i, char c) {
	int movesize = (line_len - i)+1;
	memmove(line+i+1, line+i, movesize);
	line[i] = c;
	line_len++;
}

void show_line() {
	char 	*p = line;
	char 	*s = syntax;
	int		cur_col = 0;

	if(!*p) return;

	putp(tparm(set_a_foreground, 0));

	while(*p) {
		if(*s != 127 && *s != cur_col) {
			putp(tparm(set_a_foreground, *s));
			cur_col = *s;
		}
		s++;
		putchar(*p++);
		col++;
		if(col == width) {
			col = 0;
			row++;
		}
	}
	// If we ended on the end of a row, then if we eat newlines then
	// we need to move to the right place
	// output a space and then go back to get us in the right place
	if(col == 0 && auto_right_margin && eat_newline_glitch) {
		putp(carriage_return);
		putp(cursor_down);
	}

	if(cur_col != 0) putp(tparm(set_a_foreground, 0));
}

/*
 * From where we are, get to our proposed position, for row we just
 * move up or down as needed. For col we see if we are closer to col.
 */
void move_to(int r, int c) {
	if(have_multi_move) {
		if(r > row) { putp(tparm(parm_down_cursor, r-row)); }
		if(r < row) { putp(tparm(parm_up_cursor, row-r)); }
		if(c > col) { putp(tparm(parm_right_cursor, c-col)); }
		if(c < col) { putp(tparm(parm_left_cursor, col-c)); }
		row = r;
		col = c;
	} else {
		while(r > row) { putp(cursor_down); row++; }
		while(r < row) { putp(cursor_up); row--; }
	
		if(abs(col-c) > c) {
			putp(carriage_return);
			col = 0;
		}
		while(c > col) { putp(cursor_right); col++; }
		while(c < col) { putp(cursor_left); col--; }
	}
}

/*
 * Save and restore cursor routines, not using the builtins though
 */
void save_pos() {
	srow = row;
	scol = col;
}
void restore_pos() {
	move_to(srow, scol);
}

int set_syntax(lua_State *L) {
	luaL_checktype(L, 1, LUA_TLIGHTUSERDATA);		// syntax object
	luaL_checktype(L, 2, LUA_TNUMBER);				// start pos
	luaL_checktype(L, 3, LUA_TNUMBER);				// end pos
	luaL_checktype(L, 4, LUA_TNUMBER);				// value

	char	*s = (char *)lua_topointer(L, 1);
	int		start = lua_tonumber(L, 2);
	int		end = lua_tonumber(L, 3);
	int		v = lua_tonumber(L, 4);

	int 	i;

	// We map from lua index to c...
	for(i=start-1; i <= end-1; i++) {
		s[i] = v;
	}	
	return 0;
}



void redraw_line(lua_State *L) {
	static int alloc_size = 0;

	// Make sure we have enough memory for the syntax
	// highlighting
	if(line_len > alloc_size) {
		alloc_size = line_len + 256;
		syntax = realloc(syntax, alloc_size);
		memset(syntax, 127, line_len);
	}

	// Get the function onto the stack...
	lua_rawgeti(L, LUA_REGISTRYINDEX, function_index);
	lua_pushstring(L, line);
	lua_pushlightuserdata(L, (void *)syntax);
	lua_call(L, 2, 1);

	// Show the line...
	save_pos();
	move_to(0, 0);
	show_line();
	putp(clr_eol);
	restore_pos();
}

/*
 * Move back a single char, handle wrapping back to previous line
 */
void move_back() {
	if(col == 0) {
		putp(cursor_up);
		int i;
		if(have_multi_move) {
			putp(tparm(parm_right_cursor, width));
		} else {
			for(i=0; i < width; i++) putp(cursor_right);
		}
		col = width-1;
		row--;
	} else {
		putp(cursor_left);
		col--;
	}
}
void move_on() {
	col++;
	if(col < width) {
		putp(cursor_right);
	} else {
		if(auto_right_margin && eat_newline_glitch) {
			putp(carriage_return);
			putp(cursor_down);
		}
		col = 0;
		row++;
	}
}

void int_handler(int sig) {
	printf("CLEANUP");
	ioctl(0, TCSETS, &old_termio);
	exit(1);
}


void winch_handler(int sig) {
	struct winsize	ws;

	if(ioctl(0, TIOCGWINSZ, &ws) == -1) {
		fprintf(stderr, "ioctl() err\n");
	} else {
		// Work out our current index into the line...
		int pos = (row * width) + col;

		// Update the metrics...
		width = ws.ws_col;
		height = ws.ws_row;

		// Different terms do things differently, so our safest option
		// is to clear the screen!
		// TODO: is there a better way?
		putp(clear_screen);
		row = 0;
		col = 0;
		redraw_line(0);

		// Now reposition our cursor back to where it was...
		move_to(pos/width, pos%width);

		// Make sure we update the screen...
		fflush(stdout);
	}
}




/*
 * Initialise the termcap/terminfo strings
 */
void init_terminfo_data() {
	int i, len;

	// Can we support moving the cursor multiple spaces?
	if(parm_up_cursor && parm_down_cursor && parm_left_cursor && parm_right_cursor)
		have_multi_move = 1;

	// Make sure we have the key values
	for(i=0; ti_keys[i].name; i++) {
		fprintf(stderr, "looking at %s\n", ti_keys[i].name);
		if(!ti_keys[i].data) {
			char *p = tigetstr(ti_keys[i].name);
			if((int)p > 0) {
				len = strlen(p);
				ti_keys[i].len = len;
				ti_keys[i].data = p;
				if(len < shortest_key_data) shortest_key_data = len;
				if(len > longest_key_data) longest_key_data = len;
			} else {
				fprintf(stderr, "missing terminfo key [%s] (%d)\n", ti_keys[i].name, (int)p);
			}
		}
	}

}


/*
 * Wait for up to ms milliseconds for a character and return it
 * (return 0 if no char), reduce ms by elapsed time
 */
char	get_char(int *ms) {
	struct timespec before, after;
	struct pollfd	fds[1];
	int				rc;
	char			c;

//	timeout.tv_sec = 0;
//	timeout.tv_nsec = *ms * 1000 * 1000;

	fds[0].fd = 0;
	fds[0].events = POLLIN;
	fds[0].revents = 0;

	clock_gettime(CLOCK_MONOTONIC, &before);
	rc = poll(fds, 1, 300);

	// TODO: ppoll errors?
	if(rc == 0) {
		*ms = 0;
		return 0;
	}

	clock_gettime(CLOCK_MONOTONIC, &after);
	*ms -= ((after.tv_sec - before.tv_sec)*1000) + ((after.tv_nsec - before.tv_nsec)/1000000);
	if(*ms < 0) *ms = 0;

	rc = read(0, &c, 1);
	// TODO: read errors?
	return c;
}


/*
 * Read a character and return it.
 * If the string so far is a partial match for one of our special
 * strings then wait to see if we get more characters.
 */
int	read_key() {
	static char *buffer = NULL;
	static int	bsize = 0, bpos = 0;
	int			i;

	if(!buffer) buffer = malloc(longest_key_data + 1);

	// If we have nothing buffered, then we need to read...
	if(!bsize) {
		int ms = 0;
		while(1) {
			char c = get_char(&ms);
			if(c == 0) {
				if(bsize == 0) {
					ms = 0; 
					continue;		// loop until we get something
				}
				break;
			}
			buffer[bsize++] = c;

			// Optimisation since we know all the codes start with ESC
			if(buffer[0] != 27) break;

			// See if we have a full or partial match...
			int partial = 0;
			for(i=0; ti_keys[i].name; i++) {
				if(!ti_keys[i].data) continue;

				int klen = ti_keys[i].len;
				if(strncmp(buffer, ti_keys[i].data, bsize) == 0) {
					if(klen == bsize) {
						bsize = bpos = 0;
						return ti_keys[i].rc;
					}
					partial = 1;
					if(bsize == 1) ms = 900;

					// if we are shorter than the shortest key data
					// then no need to keep looking...
					if(bsize < shortest_key_data) break;
				}
			}
			if(partial) continue;
			break;
		}
	}

	// If we have something in the buffer then we return it
	if(bsize) {
		char c = buffer[bpos];
		bsize--; bpos++;
		if(bsize == 0) bpos = 0;
		return c;
	}
	return 0;
}

int readline(lua_State *L) {
	int		rc;
	char	*termtype = getenv("TERM");

	luaL_checktype(L, 1, LUA_TFUNCTION);
	
	// push onto the stack and then get a reference
	lua_pushvalue(L, 1);
	function_index = luaL_ref(L, LUA_REGISTRYINDEX);
	

	if(!termtype) {
		fprintf(stderr, "no TERM defined!\n");
		exit(1);
	}

	ioctl(0, TCGETS, &old_termio);
	new_termio = old_termio;
	new_termio.c_lflag &= ~ECHO;
	new_termio.c_lflag &= ~ICANON;

	ioctl(0, TCSETS, &new_termio);
	

	signal(SIGQUIT, int_handler);
	signal(SIGINT, int_handler);
	signal(SIGWINCH, winch_handler);
	printf(sample);
	printf("\n");

	// Setup terminfo stuff...
	rc = setupterm((char *)0, 1, (int *)0);
	fprintf(stderr, "rc=%d\n", rc);
	
//	rc = tgetent(NULL, termtype);
//	fprintf(stderr, "rc=%d\n", rc);
//
/*	int y;
	for(y=0; strnames[y]; y++) {
		fprintf(stderr, "%d: %s\n", y, strnames[y]);
	}
	fprintf(stderr, "lines=%s\n", cursor_down);
*/
	height = lines;
	width = columns;
	printf("w=%d h=%d\n", width, height);

	col = 0;
	row = 0;

	init_terminfo_data();

	char *x = parm_down_cursor;
	printf("p=%p (%d)\n", x, strlen(x));
//	for(t=0; t < strlen(x); t++) {
//		printf("> %d  [%c] %d\n", t, x[t], x[t]);
//	}

	printf("arm=%d, eng=%d\n",  auto_right_margin, eat_newline_glitch);

//	printf(tparm(setb, 4));
	printf("HELLO\n");
//	printf(tparm(setb, 0));

	line = malloc(8192);
	strcpy(line, sample);
	line_len = strlen(line);

	int c;

	move_to((line_len/width), line_len%width);

//	show_line();
//	fflush(stdout);

	int redraw = 1;

	while(1) {
		if(redraw) {
			redraw_line(L);
			redraw = 0;
		}
		fflush(stdout);


		c = read_key();

		switch(c) {

		case KEY_LEFT:
			if(((row * width)+col) > 0) move_back();
			break;

		case KEY_RIGHT:
			if(((row * width)+col) < line_len) move_on();
			break;

		case KEY_DC:
			if(((row * width)+col) < line_len) {
				remove_char_at((row * width) + col);
				redraw = 1;
			}
			break;

		case 27:
			printf("X");
			break;

		case 127:
		case 8:
			// if we are the first char of the screen then we need to backup to the
			// end of the previous line
			//
			if(((row * width)+col) > 0) {
				move_back();
				remove_char_at((row * width) + col);
				redraw = 1;
			}
			break;

		default:
			insert_char_at((row * width) + col, c);
			move_on();
			redraw = 1;
		}
	}

	return 0;
}

/*==============================================================================
 * These are the functions we export to Lua...
 *==============================================================================
 */
static const struct luaL_reg lib[] = {
	{"readline", readline},
	{"set_syntax", set_syntax},
	//  {"serialize", do_serialize},
	//  {"unserialize", do_unserialize},
	{NULL, NULL}
};

/*------------------------------------------------------------------------------
* Main Library Entry Point ... we initialise all of our lua functions, then
* we work out what our module name is and setup mosquitto and the service
* handler
*------------------------------------------------------------------------------
*/
int luaopen_readline(lua_State *L) {
	// Initialise the library...
	luaL_openlib(L, "rl", lib, 0);
	return 1;
}






