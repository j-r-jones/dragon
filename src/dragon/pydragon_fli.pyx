"""The file-like-interface (FLI) is a class that abstracts :py:class:`dragon.channels` to a file-like API.
This is a lower-level API for efficient data transfer over :py:class:`dragon.channels`, especially for situations
where the data being communicated is not contiguous. The most common use-case is for adapting into Pickle for
object serialization.
"""
from dragon.dtypes_inc cimport *
from dragon.channels cimport *
from dragon.managed_memory cimport *
import dragon.dtypes as dtypes
import dragon.infrastructure.parameters as dparms
import dragon.infrastructure.facts as dfacts
import dragon.globalservices.channel as dgchan
from dragon.localservices.options import ChannelOptions
from dragon.rc import DragonError
import sys
import pickle

BUF_READ = PyBUF_READ
BUF_WRITE = PyBUF_WRITE
DEFAULT_CLOSE_TIMEOUT = 5
STREAM_CHANNEL_IS_MAIN = 1010

cdef enum:
    C_TRUE = 1
    C_FALSE = 0

cdef timespec_t* _computed_timeout(timeout, timespec_t* time_ptr):

    if timeout is None:
        time_ptr = NULL
    elif isinstance(timeout, int) or isinstance(timeout, float):
        if timeout < 0:
            raise ValueError('Cannot provide timeout < 0.')

        # Anything >= 0 means use that as seconds for timeout.
        time_ptr.tv_sec = int(timeout)
        time_ptr.tv_nsec =  int((timeout - time_ptr.tv_sec)*1000000000)
    else:
        raise ValueError('The timeout value must be a float or int')

    return time_ptr

class DragonFLIError(Exception):
    """
    The DragonFLIError is an exception that can be caught that explicitly targets
    those errors generated by the FLI code. The string associated with the
    exception includes any traceback avaialable from the C level interaction.
    """

    def __init__(self, lib_err, msg):
        cdef char * errstr = dragon_getlasterrstr()

        self.msg = msg
        self.lib_msg = errstr[:].decode('utf-8')
        lib_err_str = dragon_get_rc_string(lib_err)
        self.lib_err = lib_err_str[:].decode('utf-8')
        free(errstr)

    def __str__(self):
        return f"{type(self).__name__}: {self.msg}\n*** Dragon C-level Traceback: ***\n{self.lib_msg}\n*** End C-level Traceback: ***\nDragon Error Code: {self.lib_err}"

class DragonFLITimeoutError(DragonFLIError, TimeoutError):
    pass

class DragonFLIRecvdMsgDestroyedError(DragonFLIError, MemoryError):
    pass

class DragonFLIOutOfMemoryError(DragonFLIError, MemoryError):
    pass

class FLIEOT(DragonFLIError, EOFError):
    """
    The FLIEOT Exception is used to indicate the end of stream for an
    FLI conversation. This Exception inherits from EOFError so applications
    using the FLI may choose to catch EOFError instead.
    """
    pass


cdef class FLISendH:
    """
    Sending handle for FLInterfaces. A send handle is needed when sending
    data. Proper use of a send handle includes creating it (which also opens
    it for sending), sending data with one or more to the send operations,
    and closing it once data transmission is complete.
    """

    cdef:
        dragonFLISendHandleDescr_t _sendh
        dragonFLIDescr_t _adapter
        bool _is_open
        object _default_timeout

    def __init__(self, FLInterface adapter, *, Channel stream_channel=None, MemoryPool destination_pool=None, timeout=None, bool allow_strm_term=False, use_main_as_stream_channel=False, use_main_buffered=False, bool turbo_mode=False):
        """
        When creating a send handle an application may provide a stream
        channel to be used. If specifying that the main channel is to be
        used as a stream channel then both sender and receiver must agree
        to this. Both send and receive handle would need to be specified
        using the use_main_as_stream_channel in that case.

        :param adapter: An FLI over which to create a send handle.

        :param stream_channel: Default is None. The sender may supply a stream
            channel when opening a send handle. If the FLI is created with
            stream channels, then the value of the argument may be None. If
            supplied by a user then the main channel of the FLI must exist.
            If use_main_as_stream_channel is True, this argument must be
            None.

        :param use_main_as_stream_channel: Default is False. If True, then both
            send handle and receive handle must be true. This would indicate
            that both sender and receiver are agreeing they are the only
            sender and the only receiver and they wish to use the single main
            channel as the stream channel. This can be useful in some
            restricted circumstances but must only be used when there is
            exactly one sender and one receiver on the FLI.

        :param use_main_buffered: Default is False. If True, then all sends on this
            send handle must/will be buffered into one actual send operation. This
            is useful on an FLI that is not created as a buffered FLI (i.e. it allows
            streaming on stream channels), but where a process may need/want to send
            buffered data as a single message that will be deconstructed at the other
            end. The receiving side does not need to do anything different to receive
            this buffered data other than it should use recv_bytes to receive it. Calling
            recv_mem would only work for one read on the receive side and is currently
            not allowed since calling it after the first receive would not work.

        :param turbo_mode: Default is False. This tells the FLI to return immediately
            on sends with transfer of ownership. This means the sender might not be
            informed of a send failure. Receivers should have timeouts on receives to
            be guaranteed they will timeout should a failure occur. The sender
            should likely not care when turbo mode is being used.

        :param destination_pool: Default is None. This is used to indicate that messages
            that are located elsewhere should end up in this pool. This can also be a
            remote pool on a different node so long as the channel being sent to also
            resides on the same node.

        :param allow_strm_term: Default is False. When True is provided a receiver
            that closes a receive handle before the end of stream will cause the
            sender to receive an EOFError on any send operation. This allows the
            stream to be terminated by a receiver and a sender must then handle
            the EOFError exception when sending.

        :param timeout: Default is None. None means to block forever. Otherwise
            the timeout should be some number of seconds to wait for the
            operation to complete. The operation could timeout when not
            supplying a stream channel and there is no channel available
            during the specified amount of time in the manager channel. The timeout
            provided here also becomes the default timeout when used in the context
            manager framework.


        :return: An FLI send handle.
        """
        cdef:
            dragonError_t derr
            dragonChannelDescr_t * c_strm_ch = NULL
            dragonMemoryPoolDescr_t * dest_pool = NULL
            timespec_t timer
            timespec_t* time_ptr

        self._adapter = adapter._adapter
        time_ptr = _computed_timeout(timeout, &timer)

        if stream_channel is not None:
            c_strm_ch = &stream_channel._channel

        if use_main_as_stream_channel:
            c_strm_ch = STREAM_CHANNEL_IS_MAIN_FOR_1_1_CONNECTION

        if use_main_buffered:
            c_strm_ch = STREAM_CHANNEL_IS_MAIN_FOR_BUFFERED_SEND

        if destination_pool is not None:
            dest_pool = &destination_pool._pool_hdl

        with nogil:
            derr = dragon_fli_open_send_handle(&self._adapter, &self._sendh, c_strm_ch, dest_pool, allow_strm_term, turbo_mode, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Timed out while opening send handle.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not open send handle stream.")

        self._is_open = True
        self._default_timeout = timeout

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close(timeout=self._default_timeout)

    def close(self, timeout=None):
        """
        When the conversation is complete the send handle should be closed. In the case of a
        buffered FLI, no data is sent until the send handle is closed. In all cases, closing
        the send handle indicates the end of the stream for the receiver.
        """
        cdef:
            dragonError_t derr
            timespec_t timer
            timespec_t* time_ptr

        if not self._is_open:
            return

        time_ptr = _computed_timeout(timeout, &timer)

        with nogil:
            derr = dragon_fli_close_send_handle(&self._sendh, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Timed out while closing send handle.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not close send handle stream.")

        self._is_open = False

    def __del__(self):
        try:
            self.close(timeout=DEFAULT_CLOSE_TIMEOUT)
        except:
            pass

    def send_bytes(self, bytes data, uint64_t arg=0, bool buffer=False, timeout=None):
        """
        When sending bytes it is possible to specify the bytes to be sent. In addition,
        you may specify a user specified argument or hint to be sent. If buffer is true, then
        data is not actually sent on this call, but buffered for future call or until the send
        handle is closed.

        If the receiver closes the receive handle early, sending bytes may result in
        raising EOFError.
        """
        cdef:
            dragonError_t derr
            #uint8_t * c_data
            timespec_t timer
            timespec_t* time_ptr
            size_t data_len

        if self._is_open == False:
            raise RuntimeError("Handle not open, cannot send data.")

        time_ptr = _computed_timeout(timeout, &timer)

        cdef const unsigned char[:] c_data = data
        data_len = len(data)
        arg_val = arg

        with nogil:
            derr = dragon_fli_send_bytes(&self._sendh, data_len, <uint8_t *>&c_data[0], arg, buffer, time_ptr)

        if derr == DRAGON_EOT:
            raise FLIEOT(derr, "Receiver Ended Streaming")

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while sending bytes.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to send message over stream channel.")


    def send_mem(self, MemoryAlloc mem, uint64_t arg=0, transfer_ownership=True, no_copy_read_only=False, timeout=None):
        """
        Send a memory allocation with a hint (provided in arg).
        When True (the default) transfer_ownership will transfer ownership
        of the memory allocation to the sender. If a timeout is provided, then
        it will wait for that time in seconds to send it. If timeout is None
        it will wait forever if needed.

        If the receiver closes the receive handle early, sending memory may
        result in raising EOFError.
        """
        cdef:
            dragonError_t derr
            timespec_t timer
            timespec_t* time_ptr
            bool transfer
            bool nocopy

        if self._is_open == False:
            raise RuntimeError("Handle not open, cannot send data.")

        time_ptr = _computed_timeout(timeout, &timer)
        arg_val = arg
        transfer = transfer_ownership
        nocopy = no_copy_read_only

        with nogil:
            derr = dragon_fli_send_mem(&self._sendh, &mem._mem_descr, arg, transfer, nocopy, time_ptr)

        if derr == DRAGON_EOT:
            raise FLIEOT(derr, "Receiver Ended Streaming")

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while sending memory.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to send memory over stream channel.")

    def create_fd(self, bool buffered=False, size_t chunk_size=0, arg=0, timeout=None):
        """
        Opens a writable file-descriptor and returns it.
        """
        cdef:
            dragonError_t derr
            int fdes
            timespec_t timer
            timespec_t* time_ptr
            uint64_t user_arg

        if self._is_open == False:
            raise RuntimeError("Handle not open, cannot get a file descriptor.")

        time_ptr = _computed_timeout(timeout, &timer)
        user_arg = arg

        with nogil:
            derr = dragon_fli_create_writable_fd(&self._sendh, &fdes, buffered, chunk_size, user_arg, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while creating writable file descriptor.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not open writeable file descriptor.")

        return fdes

    def finalize_fd(self):
        """
        Flushes a file-descriptor and waits until all buffers are written and the
        file descriptor is closed.
        """
        cdef:
            dragonError_t derr

        if self._is_open == False:
            raise RuntimeError("Handle is not open, cannot finalize an fd on a closed send handle.")

        with nogil:
            derr = dragon_fli_finalize_writable_fd(&self._sendh)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while finalizing the writable file descriptor.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not finalize writable file descriptor")



cdef class FLIRecvH:
    """
    Receiving handle for FLInterfaces.
    """

    cdef:
        dragonFLIRecvHandleDescr_t _recvh
        dragonFLIDescr_t _adapter
        bool _is_open
        bool _close_at_exit
        object _default_timeout

    def __init__(self, FLInterface adapter, Channel stream_channel=None, MemoryPool destination_pool=None, timeout=None, use_main_as_stream_channel=False):
        """
        If specifying that the main channel is to be
        used as a stream channel then both sender and receiver must agree
        to this. Both send and receive handle would need to be specified
        using the use_main_as_stream_channel in that case.

        :param adapter: An FLI over which to create a send handle.

        :param stream_channel: Default is None. The receiver may supply a stream
            channel when opening a receive handle. If the FLI is created with
            stream channels, then the value of the argument may be None. If
            supplied by a user then the manager channel of the FLI must exist.
            If use_main_as_stream_channel is True, this argument must be
            None.

        :param use_main_as_stream_channel: Default is False. If True, then both
            send handle and receive handle must be true. This would indicate
            that both sender and receiver are agreeing they are the only
            sender and the only receiver and they wish to use the single main
            channel as the stream channel. This can be useful in some
            restricted circumstances but must only be used when there is
            exactly one sender and one receiver on the FLI.

        :param destination_pool: Default is None. If provided, it is the pool which should
            contain the message after it is received. This makes sense mainly for
            receiving memory, but other receive methods will use the pool as a transient
            storage space while receiving a message.

        :param timeout: Default is None. None means to block forever. Otherwise
            the timeout should be some number of seconds to wait for the
            operation to complete. The operation could timeout when not
            supplying a stream channel and there is no channel available
            during the specified amount of time in the manager channel. The timeout
            provided here also becomes the default timeout when used in the context
            manager framework.

        :return: An FLI send handle.
        """
        cdef:
            dragonError_t derr
            dragonChannelDescr_t * c_strm_ch = NULL
            dragonMemoryPoolDescr_t * dest_pool = NULL
            timespec_t timer
            timespec_t* time_ptr

        # This seems short, might flesh out more later
        self._adapter = adapter._adapter

        self._close_at_exit = True

        time_ptr = _computed_timeout(timeout, &timer)

        if stream_channel is not None:
            c_strm_ch = &stream_channel._channel

        if use_main_as_stream_channel:
            c_strm_ch = STREAM_CHANNEL_IS_MAIN_FOR_1_1_CONNECTION

        if destination_pool is not None:
            dest_pool = &destination_pool._pool_hdl

        with nogil:
            derr = dragon_fli_open_recv_handle(&self._adapter, &self._recvh, c_strm_ch, dest_pool, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while opening receive handle.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not open receive handle stream")

        self._is_open = True
        self._default_timeout = timeout

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        if self._close_at_exit:
            self.close()

    def no_close_on_exit(self):
        """
        Call this to avoid closing the receive handle when exiting the
        context manager. By default, the receive handle is closed when
        the context manager exits.
        """
        self._close_at_exit = False

    def close(self, timeout=None):
        """
        Close the receive handle and discard any remaining messages
        in the stream. If EOT is found, discard it. If more data
        is found than the EOT marker, raise an exception to indicate
        data was discarded.
        """
        cdef:
            dragonError_t derr
            timespec_t timer
            timespec_t* time_ptr

        if not self._is_open:
            return

        time_ptr = _computed_timeout(timeout, &timer)

        with nogil:
            derr = dragon_fli_close_recv_handle(&self._recvh, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while closing receive handle.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not close receive handle stream")

        self._is_open = False

    @property
    def is_closed(self):
        """
        Return True if the receive handle is closed and False otherwise.
        """
        return not self._is_open

    @property
    def stream_received(self):
        """
        Return True if the stream has been entirely received.
        """
        cdef:
            dragonError_t derr
            bool result

        derr = dragon_fli_stream_received(&self._recvh, &result)

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to get the stream received property")

        return result

    def __del__(self):
        try:
            self.close(timeout=DEFAULT_CLOSE_TIMEOUT)
        except:
            pass

    def recv_bytes_into(self, unsigned char[::1] bytes_buffer=None, free_mem=True, timeout=None):
        """
        Receive bytes into the bytes_buffer with timeout given in seconds. If timeout
        is None (the default) then wait forever for data. The receive handle must be
        open to call this.
        """
        cdef:
            uint64_t arg
            size_t max_bytes
            size_t num_bytes
            timespec_t timer
            timespec_t* time_ptr

        if self._is_open == False:
            raise RuntimeError("Handle is not open, cannot receive")

        time_ptr = _computed_timeout(timeout, &timer)

        max_bytes = len(bytes_buffer)

        if not free_mem:
            derr = dragon_fli_reset_free_flag(&self._recvh)
            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Error resetting free memory flag in FLI receive handle")

        # A max_bytes value of 0 means "get everything"
        # This gets a memoryview slice of the buffer
        cdef unsigned char [:] c_data = bytes_buffer
        # To pass in as a pointer, get the address of the 0th index &c_data[0]
        with nogil:
            derr = dragon_fli_recv_bytes_into(&self._recvh, max_bytes, &num_bytes, &c_data[0], &arg, time_ptr)

        if not free_mem:
            derr = dragon_fli_set_free_flag(&self._recvh)
            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Error setting free memory flag in FLI receive handle")

        if derr == DRAGON_DYNHEAP_REQUESTED_SIZE_TOO_LARGE or derr == DRAGON_MEMORY_POOL_FULL:
            raise DragonFLIOutOfMemoryError(derr, "Could not receive message because out of memory in Dragon Memory Pool. Message was discarded.")

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while receiving bytes into.")

        if derr == DRAGON_EOT:
            raise FLIEOT(derr, "End of Transmission")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not receive into bytes buffer")

        # Landing pad should be populated, just return arg
        return arg

    def recv_bytes(self, size=-1, free_mem=True, timeout=None):
        """
        Receive at most size bytes from the stream with the given timeout, which
        is given in seconds. If timeout is None, wait forever. If size is -1
        (the default) then read all available bytes.
        """
        cdef:
            dragonError_t derr
            size_t num_bytes
            size_t max_bytes = 0
            uint8_t * c_data
            uint64_t arg
            timespec_t timer
            timespec_t* time_ptr

        if self._is_open == False:
            raise RuntimeError("Handle is not open, cannot receive")

        time_ptr = _computed_timeout(timeout, &timer)

        if size > 0:
            max_bytes = size

        if not free_mem:
            derr = dragon_fli_reset_free_flag(&self._recvh)
            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Error resetting free memory flag in FLI receive handle")

        # A max_bytes value of 0 means "get everything"
        with nogil:
            derr = dragon_fli_recv_bytes(&self._recvh, max_bytes, &num_bytes, &c_data, &arg, time_ptr)

        if not free_mem:
            derr = dragon_fli_set_free_flag(&self._recvh)
            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Error setting free memory flag in FLI receive handle")

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while receiving bytes.")

        if derr == DRAGON_DYNHEAP_REQUESTED_SIZE_TOO_LARGE or derr == DRAGON_MEMORY_POOL_FULL:
            raise DragonFLIOutOfMemoryError(derr, "Could not receive message because out of memory in Dragon Memory Pool. Message was discarded.")

        if derr == DRAGON_EOT:
            if num_bytes > 0:
                free(c_data)
            raise FLIEOT(derr, "End of Transmission")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Error receiving FLI data")

        # Convert to a memoryview
        py_view = PyMemoryView_FromMemory(<char *>c_data, num_bytes, BUF_WRITE)
        # Convert memoryview to bytes
        py_bytes = py_view.tobytes()
        # Release underlying malloc now that we have a copy
        free(c_data)
        c_data = NULL
        # Return data and metadata as a tuple
        return (py_bytes, arg)

    def recv_mem(self, timeout=None):
        """
        Receive the next memory allocation/message from the stream. The timeout if
        given is in seconds. None means to wait forever.
        """
        cdef:
            dragonError_t derr
            dragonMemoryDescr_t mem
            uint64_t arg
            timespec_t timer
            timespec_t* time_ptr

        if self._is_open == False:
            raise RuntimeError("Handle is not open, cannot receive memory object")

        time_ptr = _computed_timeout(timeout, &timer)

        with nogil:
            derr = dragon_fli_recv_mem(&self._recvh, &mem, &arg, time_ptr)

        if derr == DRAGON_OBJECT_DESTROYED:
            raise DragonFLIRecvdMsgDestroyedError(derr, "The memory being received was destroyed")

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while receiving memory.")

        if derr == DRAGON_EOT:
            raise FLIEOT(derr, "End of Transmission")

        if derr == DRAGON_DYNHEAP_REQUESTED_SIZE_TOO_LARGE or derr == DRAGON_MEMORY_POOL_FULL:
            raise DragonFLIOutOfMemoryError(derr, "Could not receive message because out of memory in Dragon Memory Pool. Message was discarded.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Error receiving FLI data into memory object")

        mem_obj = MemoryAlloc.cinit(mem)
        return (mem_obj, arg)

    def create_fd(self, timeout=None):
        """
        Creates a readable file-descriptor and returns it.
        """
        cdef:
            dragonError_t derr
            int fdes
            timespec_t timer
            timespec_t* time_ptr

        if self._is_open == False:
            raise RuntimeError("Handle is not open, cannot create a file descriptor on a closed handle.")

        time_ptr = _computed_timeout(timeout, &timer)

        with nogil:
            derr = dragon_fli_create_readable_fd(&self._recvh, &fdes, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while creating readable file descriptor.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not open readable file descriptor")

        return fdes

    def finalize_fd(self):
        """
        Flushes a file-descriptor and waits until all buffers are read and the
        file descriptor is closed.
        """
        cdef:
            dragonError_t derr

        if self._is_open == False:
            raise RuntimeError("Handle is not open, cannot finalize an fd on a closed receive handle.")

        with nogil:
            derr = dragon_fli_finalize_readable_fd(&self._recvh)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while finalizing the readable file descriptor.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not finalize readable file descriptor")


cdef class FLInterface:
    """
    Cython wrapper for the File-Like-Interface
    """

    cdef:
        dragonFLIDescr_t _adapter
        dragonFLISerial_t _serial
        bool _is_serialized
        bool _is_buffered
        list stream_channel_list
        MemoryPool pool


    def __getstate__(self):
        return (self.serialize(), self.pool)

    def __setstate__(self, state):
        serial_fli, pool = state
        if pool is None or not pool.is_local:
            pool = None
        self._attach(serial_fli, pool)


    def _attach(self, ser_bytes, MemoryPool pool=None):
        cdef:
            dragonError_t derr
            dragonFLISerial_t _serial
            dragonMemoryPoolDescr_t * mpool = NULL

        if len(ser_bytes) == 0:
            raise DragonFLIError(DragonError.INVALID_ARGUMENT, "The serialized bytes were empty.")

        _serial.len = len(ser_bytes)
        cdef const unsigned char[:] cdata = ser_bytes
        _serial.data = <uint8_t *>&cdata[0]
        self._is_serialized = False
        self.pool = pool

        if pool is not None:
            mpool = &pool._pool_hdl

        derr = dragon_fli_attach(&_serial, mpool, &self._adapter)

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Could not attach to FLI adapter")

        derr = dragon_fli_is_buffered(&self._adapter, &self._is_buffered)

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to get the is buffered property")

        return self

    def __del__(self):
        if self._is_serialized:
            dragon_fli_serial_free(&self._serial)

    def __init__(self, Channel main_ch=None, Channel manager_ch=None, MemoryPool pool=None,
                        stream_channels=[], bool use_buffered_protocol=False):

        cdef:
            dragonError_t derr
            dragonChannelDescr_t ** strm_chs = NULL
            dragonChannelDescr_t * c_main_ch = NULL
            dragonChannelDescr_t * c_mgr_ch = NULL
            dragonMemoryPoolDescr_t * c_pool = NULL
            Channel ch # Necessary to cast python objects into cython objects when pulling out stream_channel values
            dragonULInt num_stream_channels

        self._is_serialized = False
        self.pool = pool

        ###
        ### If creating main and manager channels, make sure their capacity is set to the number of stream channels
        ###

        num_stream_channels = len(stream_channels)
        self._is_buffered = use_buffered_protocol

        if pool is None and main_ch is None:
            # Get default pool muid and create a main_channel from there
            default_muid = dfacts.default_pool_muid_from_index(dparms.this_process.index)
            ch_options = ChannelOptions(capacity=num_stream_channels)
            main_ch = dgchan.create(default_muid, options=ch_options)

        # Get pointers to the handles
        # This simplifies the actual C call since the pointers will either be NULL or assigned to the objects handle
        if main_ch is not None:
            c_main_ch = &main_ch._channel

        if manager_ch is not None:
            c_mgr_ch = &manager_ch._channel

        if pool is not None:
            c_pool = &pool._pool_hdl

        if num_stream_channels > 0:
            strm_chs = <dragonChannelDescr_t **>malloc(sizeof(dragonChannelDescr_t*) * num_stream_channels)
            for i in range(num_stream_channels):
                ch = stream_channels[i]
                strm_chs[i] = &ch._channel

        with nogil:
            derr = dragon_fli_create(&self._adapter, c_main_ch, c_mgr_ch, c_pool,
                                    num_stream_channels, strm_chs, use_buffered_protocol, NULL)

        if strm_chs != NULL:
            free(strm_chs) # Free our Malloc before error checking to prevent memory leaks
            strm_chs = NULL
        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to create new FLInterface")

    @classmethod
    def create_buffered(cls, Channel main_ch=None, MemoryPool pool=None):
        """
        Helper function to more easily create a simple buffered FLInterface
        Does not require any internal function, it's simply limiting the number of options for the user
        in order to make it more straightforward to make an explicitly buffered FLI
        """
        return cls(main_ch=main_ch, pool=pool, use_buffered_protocol=True)


    def destroy(self):
        """
        Free the resources of the FLI. The underlying channels are emptied (manager and main) and detached.
        """
        cdef dragonError_t derr

        with nogil:
            derr = dragon_fli_destroy(&self._adapter)

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to destroy FLInterface")

    def num_available_streams(self, timeout=None):
        """
        Return the number of available streams.
        """
        cdef:
            dragonError_t derr
            uint64_t count
            timespec_t timer
            timespec_t* time_ptr

        time_ptr = _computed_timeout(timeout, &timer)

        with nogil:
            derr = dragon_fli_get_available_streams(&self._adapter, &count, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError(derr, "Time out while getting the number of available streams.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to get the available streams")

        return count

    def serialize(self):
        """
        Return a serialized representation of the FLI that can be used to attach to it later.
        """
        cdef dragonError_t derr

        if not self._is_serialized:
            derr = dragon_fli_serialize(&self._adapter, &self._serial)

            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Failed to serialize FLInterface")

            self._is_serialized = True

        py_obj = self._serial.data[:self._serial.len]
        return py_obj

    @classmethod
    def attach(cls, serialized_bytes, mem_pool=None):
        """
        Given a serialized descriptor (in serialized_bytes), attach to an FLI.
        """
        # If mem_pool is None, the default node-local memorypool will be used
        empty_fli = cls.__new__(cls)
        return empty_fli._attach(serialized_bytes, mem_pool)

    def detach(self):
        """
        Detach from an FLI without altering it in any way.
        """
        cdef dragonError_t derr

        derr = dragon_fli_detach(&self._adapter)

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to detach from FLI adapter")

    def sendh(self, *args, **kwargs):
        """
        Return a new FLI Send Handle object
        """
        return FLISendH(self, *args, **kwargs)

    def recvh(self, *args, **kwargs):
        """
        Return a new FLI Recv Handle object
        """
        return FLIRecvH(self, *args, **kwargs)

    @property
    def is_buffered(self):
        """
        Returns True if the FLI is a buffered FLI and False otherwise.
        """
        return self._is_buffered

cdef class PickleWriteAdapter:

    cdef:
        FLISendH _sendh
        object _timeout
        object _hint

    def __init__(self, FLISendH sendh, timeout=None, hint=None):
        self._sendh = sendh
        self._timeout = timeout
        self._hint = hint

    def write(self, b):
        cdef:
            dragonError_t derr
            timespec_t timer
            timespec_t* time_ptr
            size_t length
            uint64_t arg = 0
            const unsigned char[:] sbuf

        # for large Numpy/SciPy objects
        if isinstance(b, pickle.PickleBuffer):
            sbuf = b.raw()
        else:
            sbuf = b

        length = len(sbuf)

        if self._sendh._is_open == False:
            raise RuntimeError("Handle not open, cannot send data.")

        time_ptr = _computed_timeout(self._timeout, &timer)

        if self._hint is not None:
            arg = self._hint

        with nogil:
            derr = dragon_fli_send_bytes(&self._sendh._sendh, length, <uint8_t*>&sbuf[0], arg, False, time_ptr)

        if derr == DRAGON_TIMEOUT:
            raise DragonFLITimeoutError("Time out while sending bytes.")

        if derr != DRAGON_SUCCESS:
            raise DragonFLIError(derr, "Failed to send message over stream channel.")

cdef class PickleReadAdapter:

    cdef:
        FLIRecvH _recvh
        dragonMemoryDescr_t _mem
        size_t _mem_size
        uint8_t* _mem_ptr
        size_t _offset
        object _timeout
        object _hint
        bool _free_mem
        bool _have_mem

    def __init__(self, FLIRecvH recvh, timeout=None, hint=None, free_mem=True):
        self._recvh = recvh
        self._timeout = timeout
        self._hint = hint
        self._free_mem = free_mem
        self._have_mem = False
        self._mem_size = 0
        self._offset = 0

    def __dealloc__(self):

        if self._have_mem:
            if self._free_mem:
                dragon_memory_free(&self._mem)
            self._have_mem = False

    def read(self, size=0):
        cdef:
            dragonError_t derr
            timespec_t timer
            timespec_t* time_ptr
            uint64_t arg
            size_t start = 0
            size_t end = 0

        if self._recvh._is_open == False:
            raise RuntimeError("Handle is not open, cannot receive")

        if size < 0:
            raise ValueError("Size cannot be less than zero")

        if self._offset >= self._mem_size:
            if self._have_mem:
                if self._free_mem:
                    dragon_memory_free(&self._mem)
                self._have_mem = False

            time_ptr = _computed_timeout(self._timeout, &timer)

            with nogil:
                derr = dragon_fli_recv_mem(&self._recvh._recvh, &self._mem, &arg, time_ptr)

            if derr == DRAGON_TIMEOUT:
                raise DragonFLITimeoutError(derr, "Time out while receiving bytes.")

            if derr == DRAGON_EOT:
                raise FLIEOT(derr, "End of Transmission")

            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Error receiving FLI data.")

            self._have_mem = True

            if self._hint is not None and self._hint != arg:
                raise AssertionError(f"Expected hint {self._hint} but got {arg} from FLI")

            derr = dragon_memory_get_size(&self._mem, &self._mem_size)
            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Error getting the data size.")

            self._offset = 0

            derr = dragon_memory_get_pointer(&self._mem, <void**> &self._mem_ptr)
            if derr != DRAGON_SUCCESS:
                raise DragonFLIError(derr, "Error getting the data pointer.")

        if size == 0:
            # A size of 0 means get everything.
            size = self._mem_size - self._offset

        start = self._offset

        # If start+size exceeds the memory left, then readjust size to be what's left.
        # We can return fewer bytes than was asked for.
        if start + size > self._mem_size:
            size = self._mem_size - start

        # Next time this will be where offset starts at
        self._offset = self._offset + size

        return self._mem_ptr[start:start+size]

    def readline(self):
        return self.read()