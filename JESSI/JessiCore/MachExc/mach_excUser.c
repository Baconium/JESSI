
#define	__MIG_check__Reply__mach_exc_subsystem__ 1

#include "mach_excUser.h"

#ifdef __cplusplus
extern "C" {
#endif 
extern void mach_msg_destroy(mach_msg_header_t *);
#ifdef __cplusplus
}
#endif 

#ifndef	mig_internal
#define	mig_internal	static __inline__
#endif	

#ifndef	mig_external
#define mig_external
#endif	

#if	!defined(__MigTypeCheck) && defined(TypeCheck)
#define	__MigTypeCheck		TypeCheck	
#endif	

#if	!defined(__MigKernelSpecificCode) && defined(_MIG_KERNEL_SPECIFIC_CODE_)
#define	__MigKernelSpecificCode	_MIG_KERNEL_SPECIFIC_CODE_	
#endif	

#ifndef	LimitCheck
#define	LimitCheck 0
#endif	

#ifndef	min
#define	min(a,b)  ( ((a) < (b))? (a): (b) )
#endif	

#if !defined(_WALIGN_)
#define _WALIGN_(x) (((x) + 3) & ~3)
#endif 

#if !defined(_WALIGNSZ_)
#define _WALIGNSZ_(x) _WALIGN_(sizeof(x))
#endif 

#ifndef	UseStaticTemplates
#define	UseStaticTemplates	0
#endif	

#ifndef MIG_SERVER_ROUTINE
#define MIG_SERVER_ROUTINE
#endif

#ifndef	__MachMsgErrorWithTimeout
#define	__MachMsgErrorWithTimeout(_R_) { \
	switch (_R_) { \
	case MACH_SEND_INVALID_DATA: \
	case MACH_SEND_INVALID_DEST: \
	case MACH_SEND_INVALID_HEADER: \
		mig_put_reply_port(InP->Head.msgh_reply_port); \
		break; \
	case MACH_SEND_TIMED_OUT: \
	case MACH_RCV_TIMED_OUT: \
	default: \
		mig_dealloc_reply_port(InP->Head.msgh_reply_port); \
	} \
}
#endif	

#ifndef	__MachMsgErrorWithoutTimeout
#define	__MachMsgErrorWithoutTimeout(_R_) { \
	switch (_R_) { \
	case MACH_SEND_INVALID_DATA: \
	case MACH_SEND_INVALID_DEST: \
	case MACH_SEND_INVALID_HEADER: \
		mig_put_reply_port(InP->Head.msgh_reply_port); \
		break; \
	default: \
		mig_dealloc_reply_port(InP->Head.msgh_reply_port); \
	} \
}
#endif	

#ifndef	__DeclareSendRpc
#define	__DeclareSendRpc(_NUM_, _NAME_)
#endif	

#ifndef	__BeforeSendRpc
#define	__BeforeSendRpc(_NUM_, _NAME_)
#endif	

#ifndef	__AfterSendRpc
#define	__AfterSendRpc(_NUM_, _NAME_)
#endif	

#ifndef	__DeclareSendSimple
#define	__DeclareSendSimple(_NUM_, _NAME_)
#endif	

#ifndef	__BeforeSendSimple
#define	__BeforeSendSimple(_NUM_, _NAME_)
#endif	

#ifndef	__AfterSendSimple
#define	__AfterSendSimple(_NUM_, _NAME_)
#endif	

#define msgh_request_port	msgh_remote_port
#define msgh_reply_port		msgh_local_port

#if ( __MigTypeCheck )
#if __MIG_check__Reply__mach_exc_subsystem__
#if !defined(__MIG_check__Reply__mach_exception_raise_t__defined)
#define __MIG_check__Reply__mach_exception_raise_t__defined

mig_internal kern_return_t __MIG_check__Reply__mach_exception_raise_t(__Reply__mach_exception_raise_t *Out0P)
{

	typedef __Reply__mach_exception_raise_t __Reply __attribute__((unused));
	if (Out0P->Head.msgh_id != 2505) {
	    if (Out0P->Head.msgh_id == MACH_NOTIFY_SEND_ONCE)
		{ return MIG_SERVER_DIED; }
	    else
		{ return MIG_REPLY_MISMATCH; }
	}

#if	__MigTypeCheck
	if ((Out0P->Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
	    (Out0P->Head.msgh_size != (mach_msg_size_t)sizeof(__Reply)))
		{ return MIG_TYPE_ERROR ; }
#endif	

#if	__MigTypeCheck
	if (Out0P->Head.msgh_request_port != MACH_PORT_NULL) {
		return MIG_TYPE_ERROR;
	}
#endif	
	{
		return Out0P->RetCode;
	}
}
#endif 
#endif 
#endif 

mig_external kern_return_t mach_exception_raise
(
	mach_port_t exception_port,
	mach_port_t thread,
	mach_port_t task,
	exception_type_t exception,
	mach_exception_data_t code,
	mach_msg_type_number_t codeCnt
)
{

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		
		mach_msg_body_t msgh_body;
		mach_msg_port_descriptor_t thread;
		mach_msg_port_descriptor_t task;
		
		NDR_record_t NDR;
		exception_type_t exception;
		mach_msg_type_number_t codeCnt;
		int64_t code[2];
	} Request __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
		mach_msg_trailer_t trailer;
	} Reply __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
	} __Reply __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif
	

	union {
		Request In;
		Reply Out;
	} Mess;

	Request *InP = &Mess.In;
	Reply *Out0P = &Mess.Out;

	mach_msg_return_t msg_result;
	unsigned int msgh_size;

#ifdef	__MIG_check__Reply__mach_exception_raise_t__defined
	kern_return_t check_result;
#endif	

	__DeclareSendRpc(2405, "mach_exception_raise")

#if	UseStaticTemplates
	const static mach_msg_port_descriptor_t threadTemplate = {
				MACH_PORT_NULL,
				0,
				0,
				19,
				MACH_MSG_PORT_DESCRIPTOR,
	};
#endif	

#if	UseStaticTemplates
	const static mach_msg_port_descriptor_t taskTemplate = {
				MACH_PORT_NULL,
				0,
				0,
				19,
				MACH_MSG_PORT_DESCRIPTOR,
	};
#endif	

	InP->msgh_body.msgh_descriptor_count = 2;
#if	UseStaticTemplates
	InP->thread = threadTemplate;
	InP->thread.name = thread;
#else	
	InP->thread.name = thread;
	InP->thread.disposition = 19;
	InP->thread.type = MACH_MSG_PORT_DESCRIPTOR;
#endif	

#if	UseStaticTemplates
	InP->task = taskTemplate;
	InP->task.name = task;
#else	
	InP->task.name = task;
	InP->task.disposition = 19;
	InP->task.type = MACH_MSG_PORT_DESCRIPTOR;
#endif	

	InP->NDR = NDR_record;

	InP->exception = exception;

	if (codeCnt > 2) {
		{ return MIG_ARRAY_TOO_LARGE; }
	}
	(void)memcpy((char *) InP->code, (const char *) code, 8 * codeCnt);

	InP->codeCnt = codeCnt;

	msgh_size = (mach_msg_size_t)(sizeof(Request) - 16) + ((8 * codeCnt));
	InP->Head.msgh_reply_port = mig_get_reply_port();
	InP->Head.msgh_bits = MACH_MSGH_BITS_COMPLEX|
		MACH_MSGH_BITS(19, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	
	InP->Head.msgh_request_port = exception_port;
	InP->Head.msgh_id = 2405;
	InP->Head.msgh_reserved = 0;
	

#ifdef USING_VOUCHERS
	if (voucher_mach_msg_set != NULL) {
		voucher_mach_msg_set(&InP->Head);
	}
#endif 
	

	__BeforeSendRpc(2405, "mach_exception_raise")
	msg_result = mach_msg(&InP->Head, MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, msgh_size, (mach_msg_size_t)sizeof(Reply), InP->Head.msgh_reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	__AfterSendRpc(2405, "mach_exception_raise")
	if (msg_result != MACH_MSG_SUCCESS) {
		__MachMsgErrorWithoutTimeout(msg_result);
	}
	if (msg_result != MACH_MSG_SUCCESS) {
		{ return msg_result; }
	}

#if	defined(__MIG_check__Reply__mach_exception_raise_t__defined)
	check_result = __MIG_check__Reply__mach_exception_raise_t((__Reply__mach_exception_raise_t *)Out0P);
	if (check_result != MACH_MSG_SUCCESS) {
		mach_msg_destroy(&Out0P->Head);
		{ return check_result; }
	}
#endif	

	return KERN_SUCCESS;
}

#if ( __MigTypeCheck )
#if __MIG_check__Reply__mach_exc_subsystem__
#if !defined(__MIG_check__Reply__mach_exception_raise_state_t__defined)
#define __MIG_check__Reply__mach_exception_raise_state_t__defined

mig_internal kern_return_t __MIG_check__Reply__mach_exception_raise_state_t(__Reply__mach_exception_raise_state_t *Out0P)
{

	typedef __Reply__mach_exception_raise_state_t __Reply __attribute__((unused));
#if	__MigTypeCheck
	unsigned int msgh_size;
#endif	

	if (Out0P->Head.msgh_id != 2506) {
	    if (Out0P->Head.msgh_id == MACH_NOTIFY_SEND_ONCE)
		{ return MIG_SERVER_DIED; }
	    else
		{ return MIG_REPLY_MISMATCH; }
	}

#if	__MigTypeCheck
	msgh_size = Out0P->Head.msgh_size;

	if ((Out0P->Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
	    ((msgh_size > (mach_msg_size_t)sizeof(__Reply) || msgh_size < (mach_msg_size_t)(sizeof(__Reply) - 5184)) &&
	     (msgh_size != (mach_msg_size_t)sizeof(mig_reply_error_t) ||
	      Out0P->RetCode == KERN_SUCCESS)))
		{ return MIG_TYPE_ERROR ; }
#endif	

#if	__MigTypeCheck
	if (Out0P->Head.msgh_request_port != MACH_PORT_NULL) {
		return MIG_TYPE_ERROR;
	}
#endif	
	if (Out0P->RetCode != KERN_SUCCESS) {
		return ((mig_reply_error_t *)Out0P)->RetCode;
	}

#if	__MigTypeCheck
	if ( Out0P->new_stateCnt > 1296 )
		return MIG_TYPE_ERROR;
	if (((msgh_size - (mach_msg_size_t)(sizeof(__Reply) - 5184)) / 4< Out0P->new_stateCnt) ||
	    (msgh_size != (mach_msg_size_t)(sizeof(__Reply) - 5184) + Out0P->new_stateCnt * 4))
		{ return MIG_TYPE_ERROR ; }
#endif	

	return MACH_MSG_SUCCESS;
}
#endif 
#endif 
#endif 

mig_external kern_return_t mach_exception_raise_state
(
	mach_port_t exception_port,
	exception_type_t exception,
	const mach_exception_data_t code,
	mach_msg_type_number_t codeCnt,
	int *flavor,
	const thread_state_t old_state,
	mach_msg_type_number_t old_stateCnt,
	thread_state_t new_state,
	mach_msg_type_number_t *new_stateCnt
)
{

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		exception_type_t exception;
		mach_msg_type_number_t codeCnt;
		int64_t code[2];
		int flavor;
		mach_msg_type_number_t old_stateCnt;
		natural_t old_state[1296];
	} Request __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
		int flavor;
		mach_msg_type_number_t new_stateCnt;
		natural_t new_state[1296];
		mach_msg_trailer_t trailer;
	} Reply __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
		int flavor;
		mach_msg_type_number_t new_stateCnt;
		natural_t new_state[1296];
	} __Reply __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif
	

	union {
		Request In;
		Reply Out;
	} Mess;

	Request *InP = &Mess.In;
	Reply *Out0P = &Mess.Out;

	mach_msg_return_t msg_result;
	unsigned int msgh_size;
	unsigned int msgh_size_delta;

#ifdef	__MIG_check__Reply__mach_exception_raise_state_t__defined
	kern_return_t check_result;
#endif	

	__DeclareSendRpc(2406, "mach_exception_raise_state")

	InP->NDR = NDR_record;

	InP->exception = exception;

	if (codeCnt > 2) {
		{ return MIG_ARRAY_TOO_LARGE; }
	}
	(void)memcpy((char *) InP->code, (const char *) code, 8 * codeCnt);

	InP->codeCnt = codeCnt;

	msgh_size_delta = (8 * codeCnt);
	msgh_size = (mach_msg_size_t)(sizeof(Request) - 5200) + msgh_size_delta;
	InP = (Request *) ((pointer_t) InP + msgh_size_delta - 16);

	InP->flavor = *flavor;

	if (old_stateCnt > 1296) {
		{ return MIG_ARRAY_TOO_LARGE; }
	}
	(void)memcpy((char *) InP->old_state, (const char *) old_state, 4 * old_stateCnt);

	InP->old_stateCnt = old_stateCnt;

	msgh_size += (4 * old_stateCnt);
	InP = &Mess.In;
	InP->Head.msgh_reply_port = mig_get_reply_port();
	InP->Head.msgh_bits =
		MACH_MSGH_BITS(19, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	
	InP->Head.msgh_request_port = exception_port;
	InP->Head.msgh_id = 2406;
	InP->Head.msgh_reserved = 0;
	

#ifdef USING_VOUCHERS
	if (voucher_mach_msg_set != NULL) {
		voucher_mach_msg_set(&InP->Head);
	}
#endif 
	

	__BeforeSendRpc(2406, "mach_exception_raise_state")
	msg_result = mach_msg(&InP->Head, MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, msgh_size, (mach_msg_size_t)sizeof(Reply), InP->Head.msgh_reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	__AfterSendRpc(2406, "mach_exception_raise_state")
	if (msg_result != MACH_MSG_SUCCESS) {
		__MachMsgErrorWithoutTimeout(msg_result);
	}
	if (msg_result != MACH_MSG_SUCCESS) {
		{ return msg_result; }
	}

#if	defined(__MIG_check__Reply__mach_exception_raise_state_t__defined)
	check_result = __MIG_check__Reply__mach_exception_raise_state_t((__Reply__mach_exception_raise_state_t *)Out0P);
	if (check_result != MACH_MSG_SUCCESS) {
		mach_msg_destroy(&Out0P->Head);
		{ return check_result; }
	}
#endif	

	*flavor = Out0P->flavor;

	if (Out0P->new_stateCnt > 1296) {
		(void)memcpy((char *) new_state, (const char *) Out0P->new_state, 4 *  1296);
		*new_stateCnt = Out0P->new_stateCnt;
		{ return MIG_ARRAY_TOO_LARGE; }
	}
	(void)memcpy((char *) new_state, (const char *) Out0P->new_state, 4 * Out0P->new_stateCnt);

	*new_stateCnt = Out0P->new_stateCnt;

	return KERN_SUCCESS;
}

#if ( __MigTypeCheck )
#if __MIG_check__Reply__mach_exc_subsystem__
#if !defined(__MIG_check__Reply__mach_exception_raise_state_identity_t__defined)
#define __MIG_check__Reply__mach_exception_raise_state_identity_t__defined

mig_internal kern_return_t __MIG_check__Reply__mach_exception_raise_state_identity_t(__Reply__mach_exception_raise_state_identity_t *Out0P)
{

	typedef __Reply__mach_exception_raise_state_identity_t __Reply __attribute__((unused));
#if	__MigTypeCheck
	unsigned int msgh_size;
#endif	

	if (Out0P->Head.msgh_id != 2507) {
	    if (Out0P->Head.msgh_id == MACH_NOTIFY_SEND_ONCE)
		{ return MIG_SERVER_DIED; }
	    else
		{ return MIG_REPLY_MISMATCH; }
	}

#if	__MigTypeCheck
	msgh_size = Out0P->Head.msgh_size;

	if ((Out0P->Head.msgh_bits & MACH_MSGH_BITS_COMPLEX) ||
	    ((msgh_size > (mach_msg_size_t)sizeof(__Reply) || msgh_size < (mach_msg_size_t)(sizeof(__Reply) - 5184)) &&
	     (msgh_size != (mach_msg_size_t)sizeof(mig_reply_error_t) ||
	      Out0P->RetCode == KERN_SUCCESS)))
		{ return MIG_TYPE_ERROR ; }
#endif	

#if	__MigTypeCheck
	if (Out0P->Head.msgh_request_port != MACH_PORT_NULL) {
		return MIG_TYPE_ERROR;
	}
#endif	
	if (Out0P->RetCode != KERN_SUCCESS) {
		return ((mig_reply_error_t *)Out0P)->RetCode;
	}

#if	__MigTypeCheck
	if ( Out0P->new_stateCnt > 1296 )
		return MIG_TYPE_ERROR;
	if (((msgh_size - (mach_msg_size_t)(sizeof(__Reply) - 5184)) / 4< Out0P->new_stateCnt) ||
	    (msgh_size != (mach_msg_size_t)(sizeof(__Reply) - 5184) + Out0P->new_stateCnt * 4))
		{ return MIG_TYPE_ERROR ; }
#endif	

	return MACH_MSG_SUCCESS;
}
#endif 
#endif 
#endif 

mig_external kern_return_t mach_exception_raise_state_identity
(
	mach_port_t exception_port,
	mach_port_t thread,
	mach_port_t task,
	exception_type_t exception,
	mach_exception_data_t code,
	mach_msg_type_number_t codeCnt,
	int *flavor,
	thread_state_t old_state,
	mach_msg_type_number_t old_stateCnt,
	thread_state_t new_state,
	mach_msg_type_number_t *new_stateCnt
)
{

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		
		mach_msg_body_t msgh_body;
		mach_msg_port_descriptor_t thread;
		mach_msg_port_descriptor_t task;
		
		NDR_record_t NDR;
		exception_type_t exception;
		mach_msg_type_number_t codeCnt;
		int64_t code[2];
		int flavor;
		mach_msg_type_number_t old_stateCnt;
		natural_t old_state[1296];
	} Request __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
		int flavor;
		mach_msg_type_number_t new_stateCnt;
		natural_t new_state[1296];
		mach_msg_trailer_t trailer;
	} Reply __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif

#ifdef  __MigPackStructs
#pragma pack(push, 4)
#endif
	typedef struct {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		kern_return_t RetCode;
		int flavor;
		mach_msg_type_number_t new_stateCnt;
		natural_t new_state[1296];
	} __Reply __attribute__((unused));
#ifdef  __MigPackStructs
#pragma pack(pop)
#endif
	

	union {
		Request In;
		Reply Out;
	} Mess;

	Request *InP = &Mess.In;
	Reply *Out0P = &Mess.Out;

	mach_msg_return_t msg_result;
	unsigned int msgh_size;
	unsigned int msgh_size_delta;

#ifdef	__MIG_check__Reply__mach_exception_raise_state_identity_t__defined
	kern_return_t check_result;
#endif	

	__DeclareSendRpc(2407, "mach_exception_raise_state_identity")

#if	UseStaticTemplates
	const static mach_msg_port_descriptor_t threadTemplate = {
				MACH_PORT_NULL,
				0,
				0,
				19,
				MACH_MSG_PORT_DESCRIPTOR,
	};
#endif	

#if	UseStaticTemplates
	const static mach_msg_port_descriptor_t taskTemplate = {
				MACH_PORT_NULL,
				0,
				0,
				19,
				MACH_MSG_PORT_DESCRIPTOR,
	};
#endif	

	InP->msgh_body.msgh_descriptor_count = 2;
#if	UseStaticTemplates
	InP->thread = threadTemplate;
	InP->thread.name = thread;
#else	
	InP->thread.name = thread;
	InP->thread.disposition = 19;
	InP->thread.type = MACH_MSG_PORT_DESCRIPTOR;
#endif	

#if	UseStaticTemplates
	InP->task = taskTemplate;
	InP->task.name = task;
#else	
	InP->task.name = task;
	InP->task.disposition = 19;
	InP->task.type = MACH_MSG_PORT_DESCRIPTOR;
#endif	

	InP->NDR = NDR_record;

	InP->exception = exception;

	if (codeCnt > 2) {
		{ return MIG_ARRAY_TOO_LARGE; }
	}
	(void)memcpy((char *) InP->code, (const char *) code, 8 * codeCnt);

	InP->codeCnt = codeCnt;

	msgh_size_delta = (8 * codeCnt);
	msgh_size = (mach_msg_size_t)(sizeof(Request) - 5200) + msgh_size_delta;
	InP = (Request *) ((pointer_t) InP + msgh_size_delta - 16);

	InP->flavor = *flavor;

	if (old_stateCnt > 1296) {
		{ return MIG_ARRAY_TOO_LARGE; }
	}
	(void)memcpy((char *) InP->old_state, (const char *) old_state, 4 * old_stateCnt);

	InP->old_stateCnt = old_stateCnt;

	msgh_size += (4 * old_stateCnt);
	InP = &Mess.In;
	InP->Head.msgh_reply_port = mig_get_reply_port();
	InP->Head.msgh_bits = MACH_MSGH_BITS_COMPLEX|
		MACH_MSGH_BITS(19, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	
	InP->Head.msgh_request_port = exception_port;
	InP->Head.msgh_id = 2407;
	InP->Head.msgh_reserved = 0;
	

#ifdef USING_VOUCHERS
	if (voucher_mach_msg_set != NULL) {
		voucher_mach_msg_set(&InP->Head);
	}
#endif 
	

	__BeforeSendRpc(2407, "mach_exception_raise_state_identity")
	msg_result = mach_msg(&InP->Head, MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, msgh_size, (mach_msg_size_t)sizeof(Reply), InP->Head.msgh_reply_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	__AfterSendRpc(2407, "mach_exception_raise_state_identity")
	if (msg_result != MACH_MSG_SUCCESS) {
		__MachMsgErrorWithoutTimeout(msg_result);
	}
	if (msg_result != MACH_MSG_SUCCESS) {
		{ return msg_result; }
	}

#if	defined(__MIG_check__Reply__mach_exception_raise_state_identity_t__defined)
	check_result = __MIG_check__Reply__mach_exception_raise_state_identity_t((__Reply__mach_exception_raise_state_identity_t *)Out0P);
	if (check_result != MACH_MSG_SUCCESS) {
		mach_msg_destroy(&Out0P->Head);
		{ return check_result; }
	}
#endif	

	*flavor = Out0P->flavor;

	if (Out0P->new_stateCnt > 1296) {
		(void)memcpy((char *) new_state, (const char *) Out0P->new_state, 4 *  1296);
		*new_stateCnt = Out0P->new_stateCnt;
		{ return MIG_ARRAY_TOO_LARGE; }
	}
	(void)memcpy((char *) new_state, (const char *) Out0P->new_state, 4 * Out0P->new_stateCnt);

	*new_stateCnt = Out0P->new_stateCnt;

	return KERN_SUCCESS;
}
