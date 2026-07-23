#include <Python.h>
#include <stdlib.h>
#include <string.h>

#include "FileFS.h"

static FileFS *get_ffs(PyObject *capsule)
{
	FileFS *ffs = (FileFS *)PyCapsule_GetPointer(capsule, "FileFS");
	if (ffs == NULL && !PyErr_Occurred()) {
		PyErr_SetString(PyExc_ValueError, "invalid FileFS handle");
	}
	return ffs;
}

static FFS_FILE *get_file(PyObject *capsule)
{
	FFS_FILE *file = (FFS_FILE *)PyCapsule_GetPointer(capsule, "FFS_FILE");
	if (file == NULL && !PyErr_Occurred()) {
		PyErr_SetString(PyExc_ValueError, "invalid FFS_FILE handle");
	}
	return file;
}

static FFS_DIR *get_dir(PyObject *capsule)
{
	FFS_DIR *dir = (FFS_DIR *)PyCapsule_GetPointer(capsule, "FFS_DIR");
	if (dir == NULL && !PyErr_Occurred()) {
		PyErr_SetString(PyExc_ValueError, "invalid FFS_DIR handle");
	}
	return dir;
}

static PyObject *_create(PyObject *self, PyObject *Py_UNUSED(ignored))
{
	FileFS *ffs = FileFS_create();
	if (ffs == NULL) {
		PyErr_SetString(PyExc_MemoryError, "FileFS_create failed");
		return NULL;
	}
	return PyCapsule_New(ffs, "FileFS", NULL);
}

static PyObject *_destroy(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	if (!PyArg_ParseTuple(args, "O", &capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FileFS_destroy(ffs);
	Py_RETURN_NONE;
}

static PyObject *_mkfs(PyObject *self, PyObject *args)
{
	const char *filename;
	if (!PyArg_ParseTuple(args, "s", &filename))
		return NULL;
	return PyBool_FromLong(FileFS_mkfs(filename));
}

static PyObject *_mount(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *filename;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &filename))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyBool_FromLong(FileFS_mount(ffs, filename));
}

static PyObject *_umount(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	if (!PyArg_ParseTuple(args, "O", &capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FileFS_umount(ffs);
	Py_RETURN_NONE;
}

static PyObject *_ismount(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	if (!PyArg_ParseTuple(args, "O", &capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyBool_FromLong(FileFS_ismount(ffs));
}

static PyObject *_fopen(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *filename;
	const char *mode;
	if (!PyArg_ParseTuple(args, "Oss", &capsule, &filename, &mode))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;

	FFS_FILE *file = FileFS_fopen(ffs, filename, mode);
	if (!file)
		Py_RETURN_NONE;
	return PyCapsule_New(file, "FFS_FILE", NULL);
}

static PyObject *_fread(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *file_capsule;
	Py_ssize_t size;
	Py_ssize_t nmemb;

	if (!PyArg_ParseTuple(args, "OnnO", &capsule, &size, &nmemb, &file_capsule))
		return NULL;

	if (size <= 0 || nmemb <= 0) {
		return PyBytes_FromStringAndSize(NULL, 0);
	}

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FFS_FILE *file = get_file(file_capsule);
	if (file == NULL)
		return NULL;

	size_t nbytes = (size_t)size * (size_t)nmemb;
	void *buffer = malloc(nbytes);
	if (!buffer) {
		PyErr_SetString(PyExc_MemoryError, "Failed to allocate read buffer");
		return NULL;
	}

	size_t read_n = FileFS_fread(ffs, buffer, (size_t)size, (size_t)nmemb, file);
	PyObject *result = PyBytes_FromStringAndSize((const char *)buffer, (Py_ssize_t)(read_n * (size_t)size));
	free(buffer);
	return result;
}

static PyObject *_fwrite(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *file_capsule;
	Py_buffer buffer;
	Py_ssize_t size;
	Py_ssize_t nmemb;

	if (!PyArg_ParseTuple(args, "Oy*nnO", &capsule, &buffer, &size, &nmemb, &file_capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL) {
		PyBuffer_Release(&buffer);
		return NULL;
	}
	FFS_FILE *file = get_file(file_capsule);
	if (file == NULL) {
		PyBuffer_Release(&buffer);
		return NULL;
	}

	size_t written = FileFS_fwrite(ffs, buffer.buf, (size_t)size, (size_t)nmemb, file);
	PyBuffer_Release(&buffer);
	return PyLong_FromSize_t(written);
}

static PyObject *_fclose(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *file_capsule;
	if (!PyArg_ParseTuple(args, "OO", &capsule, &file_capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FFS_FILE *file = get_file(file_capsule);
	if (file == NULL)
		return NULL;

	FileFS_fclose(ffs, file);
	Py_RETURN_NONE;
}

static PyObject *_fseek(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *file_capsule;
	long long offset;
	int whence;
	if (!PyArg_ParseTuple(args, "OOLi", &capsule, &file_capsule, &offset, &whence))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FFS_FILE *file = get_file(file_capsule);
	if (file == NULL)
		return NULL;

	return PyBool_FromLong(FileFS_fseek(ffs, file, offset, whence));
}

static PyObject *_ftell(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *file_capsule;
	if (!PyArg_ParseTuple(args, "OO", &capsule, &file_capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FFS_FILE *file = get_file(file_capsule);
	if (file == NULL)
		return NULL;

	return PyLong_FromUnsignedLongLong(FileFS_ftell(ffs, file));
}

static PyObject *_rewind(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *file_capsule;
	if (!PyArg_ParseTuple(args, "OO", &capsule, &file_capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FFS_FILE *file = get_file(file_capsule);
	if (file == NULL)
		return NULL;

	FileFS_rewind(ffs, file);
	Py_RETURN_NONE;
}

static PyObject *_file_exist(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *filename;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &filename))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyBool_FromLong(FileFS_file_exist(ffs, filename));
}

static PyObject *_dir_exist(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *pathname;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyBool_FromLong(FileFS_dir_exist(ffs, pathname));
}

static PyObject *_remove(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *filename;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &filename))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyLong_FromLong(FileFS_remove(ffs, filename));
}

static PyObject *_rename(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *old_name;
	const char *new_name;
	if (!PyArg_ParseTuple(args, "Oss", &capsule, &old_name, &new_name))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyLong_FromLong(FileFS_rename(ffs, old_name, new_name));
}

static PyObject *_move(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *from_name;
	const char *to_path;
	if (!PyArg_ParseTuple(args, "Oss", &capsule, &from_name, &to_path))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyLong_FromLong(FileFS_move(ffs, from_name, to_path));
}

static PyObject *_copy(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *from_filename;
	const char *to_filename;
	if (!PyArg_ParseTuple(args, "Oss", &capsule, &from_filename, &to_filename))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyLong_FromLong(FileFS_copy(ffs, from_filename, to_filename));
}

static PyObject *_chdir(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *pathname;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyBool_FromLong(FileFS_chdir(ffs, pathname));
}

static PyObject *_getcwd(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	if (!PyArg_ParseTuple(args, "O", &capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;

	/* FileFS_getcwd returns an internal pointer; do not free it. */
	char *cwd = FileFS_getcwd(ffs);
	if (!cwd)
		return PyUnicode_FromString("");
	return PyUnicode_FromString(cwd);
}

static PyObject *_mkdir(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *pathname;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyLong_FromLong(FileFS_mkdir(ffs, pathname));
}

static PyObject *_rmdir(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *pathname;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &pathname))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyLong_FromLong(FileFS_rmdir(ffs, pathname));
}

static PyObject *_opendir(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	const char *path;
	if (!PyArg_ParseTuple(args, "Os", &capsule, &path))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;

	char *absolute_path = NULL;
	FFS_DIR *dir = FileFS_opendir(ffs, path, &absolute_path);
	if (!dir)
		Py_RETURN_NONE;

	PyObject *dir_obj = PyCapsule_New(dir, "FFS_DIR", NULL);
	if (dir_obj == NULL)
		return NULL;

	PyObject *abs_obj;
	if (absolute_path)
		abs_obj = PyUnicode_FromString(absolute_path);
	else
		abs_obj = PyUnicode_FromString("");
	if (abs_obj == NULL) {
		Py_DECREF(dir_obj);
		return NULL;
	}

	/* absolute_path points into FileFS internal storage; do not free. */
	return Py_BuildValue("(NN)", dir_obj, abs_obj);
}

static PyObject *_readdir(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *dir_capsule;
	if (!PyArg_ParseTuple(args, "OO", &capsule, &dir_capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FFS_DIR *dir = get_dir(dir_capsule);
	if (dir == NULL)
		return NULL;

	FFS_dirent *entry = FileFS_readdir(ffs, dir);
	if (!entry)
		Py_RETURN_NONE;

	return Py_BuildValue("{s:s,s:i,s:n}",
		"name", entry->d_name,
		"type", entry->d_type,
		"namlen", (Py_ssize_t)entry->d_namlen);
}

static PyObject *_closedir(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	PyObject *dir_capsule;
	if (!PyArg_ParseTuple(args, "OO", &capsule, &dir_capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FFS_DIR *dir = get_dir(dir_capsule);
	if (dir == NULL)
		return NULL;

	FileFS_closedir(ffs, dir);
	Py_RETURN_NONE;
}

static PyObject *_begin(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	if (!PyArg_ParseTuple(args, "O", &capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyBool_FromLong(FileFS_begin(ffs));
}

static PyObject *_commit(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	if (!PyArg_ParseTuple(args, "O", &capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	return PyBool_FromLong(FileFS_commit(ffs));
}

static PyObject *_rollback(PyObject *self, PyObject *args)
{
	PyObject *capsule;
	if (!PyArg_ParseTuple(args, "O", &capsule))
		return NULL;

	FileFS *ffs = get_ffs(capsule);
	if (ffs == NULL)
		return NULL;
	FileFS_rollback(ffs);
	Py_RETURN_NONE;
}

static PyMethodDef methods[] = {
	{"create", (PyCFunction)_create, METH_NOARGS, "Create a new FileFS instance"},
	{"destroy", _destroy, METH_VARARGS, "Destroy a FileFS instance"},
	{"mkfs", _mkfs, METH_VARARGS, "Create a new filesystem image"},
	{"mount", _mount, METH_VARARGS, "Mount a filesystem image"},
	{"umount", _umount, METH_VARARGS, "Unmount a filesystem"},
	{"ismount", _ismount, METH_VARARGS, "Check if filesystem is mounted"},
	{"fopen", _fopen, METH_VARARGS, "Open a file"},
	{"fread", _fread, METH_VARARGS, "Read from a file"},
	{"fwrite", _fwrite, METH_VARARGS, "Write to a file"},
	{"fclose", _fclose, METH_VARARGS, "Close a file"},
	{"fseek", _fseek, METH_VARARGS, "Seek in a file"},
	{"ftell", _ftell, METH_VARARGS, "Get current position in file"},
	{"rewind", _rewind, METH_VARARGS, "Rewind file position"},
	{"file_exist", _file_exist, METH_VARARGS, "Check if file exists"},
	{"dir_exist", _dir_exist, METH_VARARGS, "Check if directory exists"},
	{"remove", _remove, METH_VARARGS, "Remove a file"},
	{"rename", _rename, METH_VARARGS, "Rename a file or directory"},
	{"move", _move, METH_VARARGS, "Move a file or directory into a path"},
	{"copy", _copy, METH_VARARGS, "Copy a file"},
	{"chdir", _chdir, METH_VARARGS, "Change current directory"},
	{"getcwd", _getcwd, METH_VARARGS, "Get current working directory"},
	{"mkdir", _mkdir, METH_VARARGS, "Create a directory"},
	{"rmdir", _rmdir, METH_VARARGS, "Remove a directory"},
	{"opendir", _opendir, METH_VARARGS, "Open a directory; returns (dir, absolute_path)"},
	{"readdir", _readdir, METH_VARARGS, "Read directory entry"},
	{"closedir", _closedir, METH_VARARGS, "Close a directory"},
	{"begin", _begin, METH_VARARGS, "Begin a transaction"},
	{"commit", _commit, METH_VARARGS, "Commit a transaction"},
	{"rollback", _rollback, METH_VARARGS, "Rollback a transaction"},
	{NULL, NULL, 0, NULL}
};

static struct PyModuleDef module = {
	PyModuleDef_HEAD_INIT,
	"filefs._filefs",
	"Python bindings for FileFS (C implementation)",
	-1,
	methods
};

PyMODINIT_FUNC PyInit__filefs(void)
{
	PyObject *m = PyModule_Create(&module);
	if (m == NULL)
		return NULL;

	PyModule_AddIntConstant(m, "DT_FILE", FFS_DT_FILE);
	PyModule_AddIntConstant(m, "DT_DIR", FFS_DT_DIR);
	PyModule_AddIntConstant(m, "DT_ROOT", FFS_DT_ROOT);
	PyModule_AddIntConstant(m, "SEEK_CUR", FFS_SEEK_CUR);
	PyModule_AddIntConstant(m, "SEEK_END", FFS_SEEK_END);
	PyModule_AddIntConstant(m, "SEEK_SET", FFS_SEEK_SET);
	return m;
}
