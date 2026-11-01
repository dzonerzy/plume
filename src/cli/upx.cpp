// The plume tool's way into UPX, linked in as a library (build.zig, addUpx).
//
// UPX is built with WITH_GUI: it has no main(), and where the upx command
// would exit it throws its exit code instead. upx_main() may be called again
// after it returned (it resets its options first).

int upx_main(int argc, char *argv[]);

// UPX's command line, in process: its exit code (0 success, 1 error, 2 a
// warning, as the upx command's).
extern "C" int plume_upx(int argc, char **argv) {
    try {
        return upx_main(argc, argv);
    } catch (int code) {
        return code;
    } catch (...) {
        return 1;
    }
}
