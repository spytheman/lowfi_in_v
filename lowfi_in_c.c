#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef struct Song {
    char *url;
    char *title;
    int number;
} Song;

typedef struct SongVec {
    Song *items;
    size_t len;
    size_t cap;
} SongVec;

typedef struct SongQueue {
    Song *items;
    size_t cap;
    size_t head;
    size_t tail;
    size_t count;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
} SongQueue;

typedef struct App {
    SongQueue downloaded;
} App;

typedef struct DownloadTask {
    Song song;
    int counter;
    App *app;
} DownloadTask;

static char *song_local_dir = NULL;
static SongVec songs = {0};
static int song_counter = 0;
static pthread_mutex_t song_counter_mutex = PTHREAD_MUTEX_INITIALIZER;

static void die(const char *msg) {
    perror(msg);
    exit(1);
}

static void *xmalloc(size_t size) {
    void *ptr = malloc(size);
    if (!ptr) {
        die("malloc");
    }
    return ptr;
}

static void *xrealloc(void *ptr, size_t size) {
    void *out = realloc(ptr, size);
    if (!out) {
        die("realloc");
    }
    return out;
}

static char *xstrdup(const char *s) {
    size_t len = strlen(s);
    char *out = xmalloc(len + 1);
    memcpy(out, s, len + 1);
    return out;
}

static char *xstrndup(const char *s, size_t n) {
    char *out = xmalloc(n + 1);
    memcpy(out, s, n);
    out[n] = '\0';
    return out;
}

static char *trim_line(char *line) {
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
        line[--len] = '\0';
    }
    return line;
}

static char *join_path(const char *left, const char *right) {
    size_t left_len = strlen(left);
    size_t right_len = strlen(right);
    bool need_sep = left_len > 0 && left[left_len - 1] != '/';
    char *out = xmalloc(left_len + (need_sep ? 1 : 0) + right_len + 1);
    memcpy(out, left, left_len);
    size_t pos = left_len;
    if (need_sep) {
        out[pos++] = '/';
    }
    memcpy(out + pos, right, right_len);
    out[pos + right_len] = '\0';
    return out;
}

static char *build_song_local_dir(void) {
    const char *tmp = getenv("TMPDIR");
    if (!tmp || !*tmp) {
        tmp = "/tmp";
    }
    return join_path(tmp, "lowfi");
}

static uint64_t fnv1a_64(const char *text) {
    const uint64_t offset_basis = UINT64_C(0xcbf29ce484222325);
    const uint64_t prime = UINT64_C(0x00000100000001b3);
    uint64_t hash = offset_basis;

    for (const unsigned char *p = (const unsigned char *)text; *p; ++p) {
        hash ^= (uint64_t)*p;
        hash *= prime;
    }
    return hash;
}

static char *song_local_path(const Song *song) {
    char name[64];
    snprintf(name, sizeof(name), "%llu.mp3", (unsigned long long)fnv1a_64(song->url));
    return join_path(song_local_dir, name);
}

static void song_vec_push(SongVec *vec, Song song) {
    if (vec->len == vec->cap) {
        size_t new_cap = vec->cap == 0 ? 64 : vec->cap * 2;
        vec->items = xrealloc(vec->items, new_cap * sizeof(*vec->items));
        vec->cap = new_cap;
    }
    vec->items[vec->len++] = song;
}

static Song new_song(const char *line) {
    const char *bang = strchr(line, '!');
    if (!bang) {
        Song song = {xstrdup(line), xstrdup(""), 0};
        return song;
    }

    Song song = {
        .url = xstrndup(line, (size_t)(bang - line)),
        .title = xstrdup(bang + 1),
        .number = 0,
    };
    return song;
}

static SongVec create_songs(void) {
    FILE *fp = fopen("chillhop.txt", "r");
    if (!fp) {
        die("fopen chillhop.txt");
    }

    SongVec vec = {0};
    char *line = NULL;
    size_t line_cap = 0;
    ssize_t nread;
    char *baseurl = NULL;

    while ((nread = getline(&line, &line_cap, fp)) != -1) {
        (void)nread;
        trim_line(line);
        if (!baseurl) {
            baseurl = xstrdup(line);
            continue;
        }
        if (line[0] == '\0') {
            continue;
        }

        size_t full_len = strlen(baseurl) + strlen(line);
        char *full = xmalloc(full_len + 1);
        memcpy(full, baseurl, strlen(baseurl));
        memcpy(full + strlen(baseurl), line, strlen(line));
        full[full_len] = '\0';
        song_vec_push(&vec, new_song(full));
        free(full);
    }

    free(baseurl);
    free(line);
    fclose(fp);
    return vec;
}

static void queue_init(SongQueue *q, size_t cap) {
    q->items = xmalloc(cap * sizeof(*q->items));
    q->cap = cap;
    q->head = 0;
    q->tail = 0;
    q->count = 0;
    if (pthread_mutex_init(&q->mutex, NULL) != 0) {
        die("pthread_mutex_init");
    }
    if (pthread_cond_init(&q->not_empty, NULL) != 0) {
        die("pthread_cond_init");
    }
    if (pthread_cond_init(&q->not_full, NULL) != 0) {
        die("pthread_cond_init");
    }
}

static void queue_push(SongQueue *q, Song song) {
    if (pthread_mutex_lock(&q->mutex) != 0) {
        die("pthread_mutex_lock");
    }
    while (q->count == q->cap) {
        if (pthread_cond_wait(&q->not_full, &q->mutex) != 0) {
            die("pthread_cond_wait");
        }
    }
    q->items[q->tail] = song;
    q->tail = (q->tail + 1) % q->cap;
    q->count++;
    if (pthread_cond_signal(&q->not_empty) != 0) {
        die("pthread_cond_signal");
    }
    if (pthread_mutex_unlock(&q->mutex) != 0) {
        die("pthread_mutex_unlock");
    }
}

static Song queue_pop(SongQueue *q) {
    if (pthread_mutex_lock(&q->mutex) != 0) {
        die("pthread_mutex_lock");
    }
    while (q->count == 0) {
        if (pthread_cond_wait(&q->not_empty, &q->mutex) != 0) {
            die("pthread_cond_wait");
        }
    }
    Song song = q->items[q->head];
    q->head = (q->head + 1) % q->cap;
    q->count--;
    if (pthread_cond_signal(&q->not_full) != 0) {
        die("pthread_cond_signal");
    }
    if (pthread_mutex_unlock(&q->mutex) != 0) {
        die("pthread_mutex_unlock");
    }
    return song;
}

static bool has_executable(const char *cmd) {
    const char *path = getenv("PATH");
    if (!path) {
        return false;
    }

    const char *segment = path;
    while (true) {
        const char *end = strchr(segment, ':');
        size_t len = end ? (size_t)(end - segment) : strlen(segment);
        const char *dir = len == 0 ? "." : segment;
        size_t dir_len = len == 0 ? 1 : len;
        size_t cmd_len = strlen(cmd);
        char *candidate = xmalloc(dir_len + 1 + cmd_len + 1);
        memcpy(candidate, dir, dir_len);
        candidate[dir_len] = '/';
        memcpy(candidate + dir_len + 1, cmd, cmd_len + 1);

        bool ok = access(candidate, X_OK) == 0;
        free(candidate);
        if (ok) {
            return true;
        }

        if (!end) {
            break;
        }
        segment = end + 1;
    }
    return false;
}

static void should_be_present(const char *cmd) {
    if (!has_executable(cmd)) {
        fprintf(stderr, "This program needs %s to work.\n", cmd);
        exit(1);
    }
}

static int run_command(char *const argv[]) {
    pid_t pid = fork();
    if (pid < 0) {
        return -1;
    }

    if (pid == 0) {
        execvp(argv[0], argv);
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return -1;
    }
    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return -1;
}

static int wget_file(const char *url, const char *output_path) {
    char *const argv[] = {
        (char *)"wget",
        (char *)"--quiet",
        (char *)"-O",
        (char *)output_path,
        (char *)url,
        NULL,
    };
    return run_command(argv);
}

static int mpg321_file(const char *path) {
    char *const argv[] = {
        (char *)"mpg321",
        (char *)"--quiet",
        (char *)path,
        NULL,
    };
    return run_command(argv);
}

static void remove_song(const Song *song) {
    char *path = song_local_path(song);
    (void)remove(path);
    free(path);
}

static void add_random_song(App *app);

static void download_local_file(App *app, Song osong, int counter) {
    Song song = {
        .url = osong.url,
        .title = osong.title,
        .number = counter,
    };

    char *lpath = song_local_path(&song);
    if (access(lpath, F_OK) != 0) {
        for (int i = 0; i < 5; ++i) {
            if (wget_file(song.url, lpath) != 0) {
                struct timespec ts = {
                    .tv_sec = 0,
                    .tv_nsec = 500L * 1000L * 1000L,
                };
                nanosleep(&ts, NULL);
                continue;
            }
            break;
        }
    }
    free(lpath);
    queue_push(&app->downloaded, song);
}

static void *download_local_file_thread(void *arg) {
    DownloadTask *task = arg;
    download_local_file(task->app, task->song, task->counter);
    free(task);
    return NULL;
}

static Song pick_random_song(void) {
    Song empty = {0};
    if (songs.len == 0) {
        return empty;
    }
    size_t idx = (size_t)(rand() % (int)songs.len);
    return songs.items[idx];
}

static void add_random_song(App *app) {
    Song song = pick_random_song();
    if (!song.url) {
        return;
    }

    pthread_mutex_lock(&song_counter_mutex);
    int counter = ++song_counter;
    pthread_mutex_unlock(&song_counter_mutex);

    DownloadTask *task = xmalloc(sizeof(*task));
    task->song = song;
    task->counter = counter;
    task->app = app;

    pthread_t thread;
    if (pthread_create(&thread, NULL, download_local_file_thread, task) != 0) {
        download_local_file(app, song, counter);
        free(task);
        return;
    }
    pthread_detach(thread);
}

static void add_another(App *app, Song song) {
    remove_song(&song);
    add_random_song(app);
}

int main(void) {
    srand((unsigned int)time(NULL) ^ (unsigned int)getpid());
    should_be_present("mpg321");
    should_be_present("wget");

    setvbuf(stdout, NULL, _IONBF, 0);

    song_local_dir = build_song_local_dir();
    if (mkdir(song_local_dir, 0755) != 0 && errno != EEXIST) {
        die("mkdir");
    }
    printf("Local folder: %s\n", song_local_dir);

    songs = create_songs();

    App app = {0};
    queue_init(&app.downloaded, 5);

    for (int i = 0; i < 5; ++i) {
        add_random_song(&app);
    }

    for (;;) {
        Song song = queue_pop(&app.downloaded);
        printf("Playing \"%s\" from URL: %-40s ...\n", song.title, song.url);
        char *path = song_local_path(&song);
        int res = mpg321_file(path);
        free(path);
        printf("res: %d\n", res);
        if (res == 4) {
            fprintf(stderr, "mpv was interrupted by Ctrl-C. Good bye.\n");
            exit(1);
        }
        add_another(&app, song);
    }
}
